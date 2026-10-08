#!/usr/bin/env python3
"""Тест драйвера мастера установки (scripts/wizard.py) на записанном диалоге — без Docker и сети.

  python3 tests/test_wizard.py                     воспроизвести записи tests/fixtures/wizard-*.jsonl
  python3 tests/test_wizard.py --diff новая.jsonl  чем свежая запись отличается от сохранённой: шаги, поля, этапы

Запись делает сам драйвер: BX_WIZARD_RECORD=файл.jsonl bx install … (в CI — еженедельная матрица).
Воспроизведение: драйвер получает записанные ответы мастера и должен отправить ровно те же запросы,
что и при настоящей установке. Если Битрикс поменяет мастер, свежая запись в --diff покажет, что именно
изменилось, а воспроизведение старой записи останется зелёным — это проверка самого драйвера.
"""
import argparse
import difflib
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import wizard  # noqa: E402

FIXTURES = os.path.join(ROOT, "tests", "fixtures")


def load(path):
    with open(path, encoding="utf-8") as f:
        lines = [json.loads(line) for line in f if line.strip()]
    if not lines or "args" not in lines[0]:
        raise SystemExit(f"{path}: первая строка должна содержать параметры запуска (args)")
    return lines[0]["args"], lines[1:]


class Replay(wizard.Wizard):
    """Вместо сети — записанные ответы; каждый запрос сверяется с записанным."""

    def __init__(self, args, entries, name):
        super().__init__("http://replay", args)
        self.entries, self.pos, self.name = entries, 0, name

    def request(self, path, data=None):
        if self.pos >= len(self.entries):
            raise AssertionError(f"{self.name}: драйвер отправил лишний запрос {path} {data}")
        e = self.entries[self.pos]
        got = self.mask(data)
        if path != e["path"] or got != e["data"]:
            diff = "\n".join(difflib.unified_diff(
                json.dumps(e["data"], ensure_ascii=False, indent=1, sort_keys=True).splitlines(),
                json.dumps(got, ensure_ascii=False, indent=1, sort_keys=True).splitlines(),
                "записано", "отправлено", lineterm=""))
            raise AssertionError(f"{self.name}: запрос №{self.pos + 1} ({e['path']}) отличается от записанного:\n{diff}")
        self.pos += 1
        return e["response"]

    def log(self, msg):
        pass


def replay(path):
    rec_args, entries = load(path)
    args = argparse.Namespace(**rec_args)
    for k in wizard.Wizard.SECRET_ARGS:         # секреты в записи — метки; подставляем их же
        setattr(args, k, f"<{k}>")
    w = Replay(args, entries, os.path.basename(path))
    w.run()
    rest = [e for e in entries[w.pos:] if not (e["path"] == "/" and e["data"] is None)]
    if rest:
        raise AssertionError(f"{w.name}: драйвер остановился раньше, осталось записанных запросов: {len(rest)}")
    return w.pos


def structure(path):
    """Краткое описание мастера по записи: шаги и их поля, этапы AJAX-циклов."""
    _, entries = load(path)
    out, seen_stages = [], set()
    for e in entries:
        r = e["response"]
        if r.startswith("[response]"):
            for step, stage in re.findall(r"nextStep['\"]?\s*:\s*['\"]([^'\"]*)['\"].*?nextStepStage['\"]?\s*:\s*['\"]([^'\"]*)", r, re.S) \
                    or re.findall(r"Post\(\s*'([^']*)'\s*,\s*'([^']*)'", r):
                if (step, stage) not in seen_stages:
                    seen_stages.add((step, stage))
                    out.append(f"    этап: {step}/{stage}")
            continue
        for form in wizard.Wizard.forms(r):
            sid = wizard.Wizard.step_id(form)
            if not sid:
                continue
            fields = sorted({f"{f[2]}:{f[1]}" if f[0] == "input" else f"{f[1]['name']}:select" if f[0] == "select"
                             else f"{f[1][0]}:textarea" for f in form["fields"]
                             if not (f[0] == "input" and (f[2] or "").startswith(("CurrentStepID", "PreviousStepID", "NextStepID", "sessid")))})
            ajax = " (AJAX)" if "new CAjaxForm" in r else ""
            line = f"шаг {sid}{ajax}: {', '.join(x for x in fields if not x.startswith('None'))}"
            if not out or out[-1] != line:
                out.append(line)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--diff", metavar="ЗАПИСЬ", help="сравнить свежую запись с сохранённой (той же редакции)")
    ap.add_argument("--against", metavar="ЗАПИСЬ", help="с какой сохранённой записью сравнивать (по умолчанию wizard-standard)")
    a = ap.parse_args()

    if a.diff:
        old = a.against or os.path.join(FIXTURES, "wizard-standard.jsonl")
        d = list(difflib.unified_diff(structure(old), structure(a.diff), "сохранённая запись", "свежая запись", lineterm=""))
        if d:
            print("\n".join(d))
            # аннотация в GitHub Actions: заметна в сводке прогона, но прогон не роняет
            print("::warning::Мастер установки Битрикса изменился (шаги или поля) — проверьте scripts/wizard.py "
                  "и обновите tests/fixtures (подробности в выводе шага)")
        else:
            print("Мастер не изменился: шаги и поля совпадают с сохранённой записью.")
        return

    files = sorted(glob.glob(os.path.join(FIXTURES, "wizard-*.jsonl")))
    if not files:
        raise SystemExit("Нет записей tests/fixtures/wizard-*.jsonl")
    fails = 0
    for f in files:
        try:
            n = replay(f)
            print(f"  [ok]   {os.path.basename(f)}: {n} запросов совпали с записью")
        except (AssertionError, SystemExit) as e:
            fails += 1
            print(f"  [FAIL] {os.path.basename(f)}: {e}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

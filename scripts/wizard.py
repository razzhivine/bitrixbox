#!/usr/bin/env python3
"""Проходит мастер установки 1С-Битрикс по HTTP, без браузера.

Запускается командой `bx install` (или `bx setup --install`). Настройки базы берёт из .env.
Работает с редакциями, которые ставятся из архива (start, standard, small_business, business).
Мастер устроен как набор шагов (CurrentStepID) и AJAX-циклов с ответами вида [response]JS[/response];
драйвер повторяет то, что делает JavaScript страницы. Неизвестный шаг не угадывается: драйвер
останавливается и просит продолжить в браузере.
"""
import argparse
import html
import http.cookiejar
import os
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

SOLUTIONS = {
    "corp_furniture": "bitrix.sitecorporate:bitrix:corp_furniture",
    "corp_services": "bitrix.sitecorporate:bitrix:corp_services",
}


class FormParser(HTMLParser):
    """Собирает формы страницы мастера: поля input/select/textarea."""

    def __init__(self):
        super().__init__()
        self.forms, self.cur, self._sel, self._ta = [], None, None, None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self.cur = {"action": a.get("action", ""), "fields": []}
            self.forms.append(self.cur)
        elif self.cur is not None:
            if tag == "input":
                self.cur["fields"].append(("input", a.get("type", "text"), a.get("name"), a.get("value", ""), "checked" in a))
            elif tag == "select":
                self._sel = {"name": a.get("name"), "opts": [], "selected": None}
                self.cur["fields"].append(("select", self._sel))
            elif tag == "option" and self._sel is not None:
                self._sel["opts"].append(a.get("value", ""))
                if "selected" in a:
                    self._sel["selected"] = a.get("value", "")
            elif tag == "textarea":
                self._ta = [a.get("name"), ""]
                self.cur["fields"].append(("textarea", self._ta))

    def handle_endtag(self, tag):
        if tag == "select":
            self._sel = None
        elif tag == "textarea":
            self._ta = None

    def handle_data(self, data):
        if self._ta is not None:
            self._ta[1] += data


def form_data(form, submit="StepNext"):
    """Значения полей формы так, как отправил бы браузер."""
    data = {}
    for f in form["fields"]:
        if f[0] == "input":
            _, typ, name, val, checked = f
            if not name or typ == "button" or typ == "file":
                continue
            if typ in ("checkbox", "radio") and not checked:
                continue
            if typ == "submit" and name != submit:
                continue
            data[name] = val
        elif f[0] == "select":
            s = f[1]
            data[s["name"]] = s["selected"] if s["selected"] is not None else (s["opts"][0] if s["opts"] else "")
        else:
            data[f[1][0]] = f[1][1]
    return data


def page_text(t):
    s = re.sub(r"<script.*?</script>|<style.*?</style>", "", t, flags=re.S)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s))).strip()


class Wizard:
    def __init__(self, base, args):
        self.base, self.args = base.rstrip("/"), args
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.last_status = None

    # ---- сеть
    def request(self, path, data=None):
        url = self.base + path
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        try:
            with self.opener.open(urllib.request.Request(url, body), timeout=1200) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            raise SystemExit(f"Сервер ответил {e.code} на {path}. Подробности: bx logs")
        except urllib.error.URLError as e:
            raise SystemExit(f"Нет связи с {url}: {e.reason}. Контейнеры запущены? (bx status)")

    def log(self, msg):
        print(msg, flush=True)

    # ---- разбор страницы
    @staticmethod
    def forms(t):
        p = FormParser()
        p.feed(t)
        return [f for f in p.forms if f["fields"]]

    @staticmethod
    def step_id(form):
        for f in form["fields"]:
            if f[0] == "input" and f[2] == "CurrentStepID":
                return f[3]
        return None

    @staticmethod
    def is_ajax(t):
        return "new CAjaxForm" in t

    # ---- AJAX-цикл (шаги, где страница сама шлёт запросы и получает JS в [response]…[/response])
    def run_ajax(self, form):
        data = form_data(form)
        for _ in range(2000):
            t = self.request(form["action"] or "/", data)
            m = re.search(r"\[response\](.*?)\[/response\]", t, re.S | re.I)
            if not m:
                return t  # обычная страница — следующий шаг мастера
            js = m.group(1)
            pct = re.search(r"SetStatus\(\s*'?(\d+)'?", js)
            status = None
            obj = re.search(r"ajaxForm\.Post\(\s*(\{.*?\})\s*,\s*(['\"])(.*?)\2", js, re.S)
            pos = re.search(r"ajaxForm\.Post\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'", js)
            if obj:
                # значения бывают в кавычках ('check,upgrade') и числами без кавычек (0)
                for k, v1, v2 in re.findall(r"""['"]?(\w+)['"]?\s*:\s*(?:['"]([^'"]*)['"]|(-?\d+))""", obj.group(1)):
                    data["__wiz_" + k] = v1 if v1 or not v2 else v2
                status = obj.group(3)
            elif pos:
                data["__wiz_nextStep"], data["__wiz_nextStepStage"], status = pos.group(1), pos.group(2), pos.group(3)
            else:
                raise SystemExit("Мастер вернул неожиданный ответ (формат не распознан):\n" + js.strip()[:600])
            if status and status != self.last_status:
                self.last_status = status
                self.log(f"   [{pct.group(1) + '%' if pct else '...':>4}] {html.unescape(status)}")
        raise SystemExit("Слишком много шагов в AJAX-цикле — остановился")

    # ---- обработчики шагов
    def handle(self, form, t):
        """Возвращает ответ мастера на текущий шаг."""
        sid = self.step_id(form)
        a = self.args
        data = form_data(form)
        post_form = lambda d: self.request(form["action"] or "/", d)  # noqa: E731

        if self.is_ajax(t) and sid == "update_modules" and a.skip_updates:
            # то же, что кнопка «Пропустить шаг»: сразу переходим к завершению этого шага мастера
            self.log(f" - {sid}: пропускаю (--skip-updates)")
            data["__wiz_nextStep"], data["__wiz_nextStepStage"] = "__finish", "dummy"
            return post_form(data)

        if self.is_ajax(t):
            self.log(f" - {sid}: выполняется")
            return self.run_ajax(form)

        self.log(f" - {sid}")
        if sid in ("welcome", "requirements", "select_template", "select_theme"):
            pass
        elif sid == "agreement":
            data["__wiz_agree_license"] = "Y"
        elif sid == "check_license_key":
            if a.register:
                # регистрация копии на сервере 1С-Битрикс: туда уходят имя, фамилия и почта
                data.update({
                    "__wiz_lic_key_variant": "Y",
                    "__wiz_user_name": a.reg_name, "__wiz_user_surname": a.reg_surname, "__wiz_email": a.reg_email,
                })
            else:
                data["__wiz_lic_key_variant"] = ""  # без регистрации: личные данные никуда не уходят
        elif sid == "create_database":
            data.update({
                "__wiz_host": a.db_host, "__wiz_create_user": "N", "__wiz_user": a.db_user,
                "__wiz_password": a.db_password, "__wiz_create_database": "N", "__wiz_database": a.db_name,
            })
        elif sid == "create_admin":
            data.update({
                "__wiz_login": a.admin_login, "__wiz_admin_password": a.admin_password,
                "__wiz_admin_password_confirm": a.admin_password, "__wiz_email": a.admin_email,
                "__wiz_user_name": a.admin_name, "__wiz_user_surname": a.admin_surname,
            })
        elif sid == "select_wizard":
            data["__wiz_selected_wizard"] = SOLUTIONS[a.solution]
        elif sid == "site_settings":
            data["__wiz_installDemoData"] = "Y" if a.demo == "yes" else "N"
        elif sid == "finish":
            return post_form(data)
        elif not any(f[0] != "input" or f[1] in ("text", "password", "checkbox", "radio", "file") for f in form["fields"]):
            pass  # информационный шаг без полей (например, показ полученного ключа): просто «Далее»
        else:
            raise SystemExit(
                f"Неизвестный шаг мастера «{sid}». Дальше пройдите установщик в браузере: {self.base}/\n"
                f"(текст шага: {page_text(t)[page_text(t).find('Установка'):][:200]})")
        return post_form(data)

    def run(self, t=None):
        t = t if t is not None else self.request("/")
        prev = None
        for _ in range(60):
            forms = self.forms(t)
            sid = self.step_id(forms[0]) if forms else None
            if sid is None:
                break
            if sid == prev and not self.is_ajax(t):
                # тот же шаг вернулся: мастер не принял данные — покажем его сообщение
                text = page_text(t)
                raise SystemExit(f"Шаг «{sid}» не принят мастером: {text[text.find('Установка'):][:400]}")
            prev = sid
            t = self.handle(forms[0], t)
            if sid == "finish":
                break
        return t


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True, help="адрес сайта, например http://localhost:8080")
    ap.add_argument("--db-host", default="db")
    ap.add_argument("--db-name", required=True)
    ap.add_argument("--db-user", required=True)
    ap.add_argument("--db-password", required=True)
    ap.add_argument("--admin-login", default="admin")
    ap.add_argument("--admin-password", default="")
    ap.add_argument("--admin-email", default="admin@example.com")
    ap.add_argument("--admin-name", default="Admin")
    ap.add_argument("--admin-surname", default="Admin")
    ap.add_argument("--register", action="store_true",
                    help="зарегистрировать копию на сервере 1С-Битрикс (отправляет имя, фамилию и почту; нужны --reg-*)")
    ap.add_argument("--reg-name", default="")
    ap.add_argument("--reg-surname", default="")
    ap.add_argument("--reg-email", default="")
    ap.add_argument("--skip-updates", action="store_true",
                    help="не ставить обновления в мастере (потом: bx update); установка идёт быстрее")
    ap.add_argument("--solution", choices=sorted(SOLUTIONS), default="corp_furniture")
    ap.add_argument("--demo", choices=["yes", "no"], default="yes",
                    help="ставить демо-данные решения (по умолчанию да). С «no» Битрикс не копирует страницы сайта "
                         "и корневой index.php остаётся запуском мастера — сайт получается недоустановленным")
    args = ap.parse_args()

    if args.register:
        missing = [n for n, v in (("--reg-name", args.reg_name), ("--reg-surname", args.reg_surname),
                                  ("--reg-email", args.reg_email)) if not v.strip()]
        if missing:
            sys.exit("Для --register нужны ваши настоящие данные: " + ", ".join(missing)
                     + ".\nОни отправляются на сервер 1С-Битрикс при регистрации копии; заглушки подставлять не буду.")
        if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", args.reg_email):
            sys.exit(f"--reg-email: «{args.reg_email}» не похоже на адрес почты")

    generated = False
    if not args.admin_password:
        args.admin_password = secrets.token_hex(8)
        generated = True

    print(f"Установка Битрикса через мастер: {args.url}" + ("  (с регистрацией продукта)" if args.register else "  (без регистрации продукта)"))
    w = Wizard(args.url, args)
    w.run()

    # проверка результата: главная открывается, установщик больше не отдаётся
    page = w.request("/")
    if "CurrentStepID" in page:
        raise SystemExit("Мастер не дошёл до конца: на главной всё ещё установщик. Продолжите в браузере.")
    print("\nГотово: Битрикс установлен.")
    print(f"  Админка:  {args.url}/bitrix/admin/")
    print(f"  Логин:    {args.admin_login}")
    print(f"  Пароль:   {args.admin_password}" + ("   (сгенерирован — сохраните)" if generated else ""))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)

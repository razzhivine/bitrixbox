# Общие настройки сайта Битрикс: подключаются и в http-, и в https-сервер
root /var/www/html;
index index.php;
client_max_body_size 100m;
charset utf-8;

# Корень сайта: идём в /index.php; если его нет (после очистки демо-данных), сработает @bitrix
# (в try_files нельзя писать $uri/index.php: найденный файл отдался бы как статика, без PHP)
location = / {
    rewrite ^ /index.php last;
}

location / {
    try_files $uri $uri/ @bitrix;
}

location @bitrix {
    fastcgi_pass php:9000;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $document_root/bitrix/urlrewrite.php;
    fastcgi_read_timeout 300;
}

# закрываем служебные папки
location ~ ^/(bitrix/(modules|local_cache|stack_cache|managed_cache|php_interface)|upload/support/not_image)/ {
    deny all;
}

# в upload PHP не исполняем (аналог upload/.htaccess для Apache)
location ~* ^/upload/.*\.(php|phtml|phar)$ { deny all; }

location ~ \.php$ {
    try_files $uri @bitrix;
    fastcgi_pass php:9000;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_read_timeout 300;
}

location ~ /\.(ht|git) { deny all; }

location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff2?)$ {
    expires 1h;
    try_files $uri @bitrix;
}

#!/bin/bash
# AI 错题本 同步服务一键安装（宝塔 + nginx + Let's Encrypt IP 证书）
# 用法：bash setup.sh   （需 root；ctb_sync.py 与本脚本放同一目录）
set -u
IP=124.223.170.26
HOME_DIR=/opt/ctb-sync
HERE=$(cd "$(dirname "$0")" && pwd)
say(){ echo; echo "==== $* ===="; }

say 1. 安装同步程序
mkdir -p $HOME_DIR/www/.well-known/acme-challenge
cp "$HERE/ctb_sync.py" $HOME_DIR/ctb_sync.py
if [ ! -s $HOME_DIR/codes.txt ]; then
  python3 -c "import secrets;print('ctb-'+secrets.token_urlsafe(12))" > $HOME_DIR/codes.txt
fi
PY=$(command -v python3)
cat > /etc/systemd/system/ctb-sync.service <<EOF
[Unit]
Description=AI cuotiben sync
After=network.target
[Service]
ExecStart=$PY $HOME_DIR/ctb_sync.py
Environment=CTB_HOME=$HOME_DIR
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now ctb-sync && sleep 1
curl -s http://127.0.0.1:8790/ && echo " <- 同步程序已运行"

say 2. 找 nginx
NGX=/www/server/nginx/sbin/nginx; VH=/www/server/panel/vhost/nginx
if [ ! -x $NGX ]; then NGX=$(command -v nginx || true); VH=/etc/nginx/conf.d; fi
if [ -z "$NGX" ]; then echo "没找到 nginx，请在宝塔「软件商店」安装 Nginx 后再运行本脚本"; exit 1; fi
echo "nginx: $NGX  配置目录: $VH"
mkdir -p $VH

say 3. 80 端口验证用配置
WEB=$HOME_DIR/www
rm -f $VH/ctb-sync-80.conf
# 宝塔里如果已有站点用了这个 IP 当域名，就借用那个站点的网站目录做验证
OLD=$(grep -lsE "server_name[^;]*[[:space:]]$IP([[:space:];]|$)" $VH/*.conf 2>/dev/null | grep -v ctb-sync | head -1)
if [ -n "$OLD" ]; then
  R=$(grep -m1 -E "^[[:space:]]*root[[:space:]]" "$OLD" | sed -E 's/^[[:space:]]*root[[:space:]]+//; s/;.*//')
  echo "已有站点占用该 IP: $OLD  网站目录: $R"
  [ -n "$R" ] && WEB=$R
else
  DEF=""; grep -rqs "listen 80 default_server\|listen 80 default" $VH /www/server/nginx/conf/nginx.conf 2>/dev/null || DEF=" default_server"
  cat > $VH/ctb-sync-80.conf <<EOF2
server {
  listen 80$DEF;
  server_name $IP;
  location ^~ /.well-known/acme-challenge/ { root $HOME_DIR/www; }
}
EOF2
fi
mkdir -p $WEB/.well-known/acme-challenge
$NGX -t && $NGX -s reload
echo ok-ctb > $WEB/.well-known/acme-challenge/ping
sleep 1; echo -n "验证路径自测: "; T=$(curl -s http://$IP/.well-known/acme-challenge/ping); echo "$T"
if [ "$T" != "ok-ctb" ]; then echo "验证路径不通，先停在这里。请把这一屏截图发给 Hark"; exit 1; fi

say 4. 申请 IP 证书（Lets Encrypt shortlived，自动续期）
if [ ! -x ~/.acme.sh/acme.sh ]; then
  curl -s --max-time 60 https://get.acme.sh | sh >/dev/null 2>&1
fi
if [ ! -x ~/.acme.sh/acme.sh ]; then
  echo "官方源失败，改用 gitee 镜像"
  (cd /tmp && rm -rf acme.sh && git clone --depth 1 https://gitee.com/neilpang/acme.sh.git && cd acme.sh && ./acme.sh --install >/dev/null)
fi
AC=~/.acme.sh/acme.sh
$AC --set-default-ca --server letsencrypt >/dev/null
$AC --issue --server letsencrypt -d $IP -w $WEB --certificate-profile shortlived --days 3 --force || { echo "证书申请失败，请把这一屏截图发给 Hark"; exit 1; }
mkdir -p $HOME_DIR/ssl
$AC --install-cert -d $IP --key-file $HOME_DIR/ssl/key.pem --fullchain-file $HOME_DIR/ssl/full.pem --reloadcmd "$NGX -s reload"
ls -l $HOME_DIR/ssl

say 5. 443 https 配置
cat > $VH/ctb-sync-443.conf <<EOF
server {
  listen 443 ssl;
  server_name $IP;
  ssl_certificate $HOME_DIR/ssl/full.pem;
  ssl_certificate_key $HOME_DIR/ssl/key.pem;
  client_max_body_size 64m;
  location /ctb-sync/ { proxy_pass http://127.0.0.1:8790; proxy_read_timeout 120s; }
  location / { return 404; }
}
EOF
$NGX -t && $NGX -s reload

say 6. 自测
curl -s https://$IP/ctb-sync/api && echo " <- https 正常"
echo
echo "同步码（填到错题本「设置→多设备同步」）："
cat $HOME_DIR/codes.txt
echo "全部完成"

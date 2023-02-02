#!/usr/bin/env bash
silent() { "$@" > /dev/null 2>&1; }
if [ "$VERBOSE" == "yes" ]; then set -x; fi
if [ "$DISABLEIPV6" == "yes" ]; then echo "net.ipv6.conf.all.disable_ipv6 = 1" >>/etc/sysctl.conf; $STD sysctl -p; fi
YW=$(echo "\033[33m")
RD=$(echo "\033[01;31m")
BL=$(echo "\033[36m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
RETRY_NUM=10
RETRY_EVERY=3
NUM=$RETRY_NUM
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
BFR="\\r\\033[K"
HOLD="-"
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR

function error_exit() {
        trap - ERR
        local reason="Unknown failure occurred."
        local msg="${1:-$reason}"
        local flag="${RD}‼ ERROR ${CL}$EXIT@$LINE"
        echo -e "$flag $msg" 1>&2
        exit $EXIT
}

function msg_info() {
        local msg="$1"
        echo -ne " ${HOLD} ${YW}${msg}..."
}

function msg_ok() {
        local msg="$1"
        echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

function msg_error() {
        local msg="$1"
        echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

msg_info "Setting up Container OS "
sed -i "/$LANG/ s/\(^# \)//" /etc/locale.gen
locale-gen >/dev/null
while [ "$(hostname -I)" = "" ]; do
        echo 1>&2 -en "${CROSS}${RD} No Network! "
        sleep $RETRY_EVERY
        ((NUM--))
        if [ $NUM -eq 0 ]; then
                echo 1>&2 -e "${CROSS}${RD} No Network After $RETRY_NUM Tries${CL}"
                exit 1
        fi
done
msg_ok "Set up Container OS"
msg_ok "Network Connected: ${BL}$(hostname -I)"

set +e
alias die=''
if nc -zw1 8.8.8.8 443; then msg_ok "Internet Connected"; else
  msg_error "Internet NOT Connected"
    read -r -p "Would you like to continue anyway? <y/N> " prompt
    if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]]; then
      echo -e " ⚠️  ${RD}Expect Issues Without Internet${CL}"
    else
      echo -e " 🖧  Check Network Settings"
      exit 1
    fi
fi
RESOLVEDIP=$(nslookup "github.com" | awk -F':' '/^Address: / { matched = 1 } matched { print $2}' | xargs)
if [[ -z "$RESOLVEDIP" ]]; then msg_error "DNS Lookup Failure"; else msg_ok "DNS Resolved github.com to $RESOLVEDIP"; fi
alias die='EXIT=$? LINE=$LINENO error_exit'
set -e

msg_info "Updating Container OS"
$STD apt-get update
$STD apt-get -y upgrade
msg_ok "Updated Container OS"

msg_info "Installing Tandoor Recipes Dependencies"
apt-get install -y --no-install-recommends \
	python3 \
	python3-pip \
	python3-venv \
        nginx \
	sudo &>/dev/null
msg_ok "Installed Tandoor Recipes Dependencies"

msg_info "Installing postgresql Dependencies"
apt-get install -y --no-install-recommends \
        libpq-dev \
        postgresql &>/dev/null
msg_ok "Installed postgresql Dependencies"

msg_info "Installing LDAP Dependencies"
apt-get install -y --no-install-recommends \
        libsasl2-dev \
        python3-dev \
        libldap2-dev \
        libssl-dev &>/dev/null
msg_ok "Installed postgresql Dependencies"

msg_info "Downloading Tandoor Recipes"
last_release=$(wget -q https://github.com/TandoorRecipes/recipes/releases/latest -O - | grep "title>Release" | cut -d " " -f 5)
cd /tmp &&
	wget https://github.com/TandoorRecipes/recipes/releases/download/$last_release/recipes-$last_release.tar.xz &>/dev/null &&
	tar -xf recipes-$last_release.tar.xz -C /opt/ &>/dev/null &&
	mv recipes /var/www &&
	rm recipes-$last_release.tar.xz
cd /var/www/recipes

chown -R recipes:www-data /var/www/recipes

python3 -m venv /var/www/recipes

msg_info "Setting up Node.js Repository"
$STD bash <(curl -fsSL https://deb.nodesource.com/setup_16.x)
msg_ok "Set up Node.js Repository"

msg_info "Installing Node.js"
apt-get install -y nodejs
msg_ok "Installed Node.js"

msg_info "Installing yarn"
$STD npm install --global yarn &> /dev/null
msg_ok "Installed yarn"

msg_info "Creating the python virtual environment"
/var/www/recipes/bin/pip3 install -r requirements.txt
msg_info "Created the python virtual environment"


msg_info "Installing frontend requirements"
cd ./vue
yarn install
yarn build
msg_ok "Installed frontend requirements"

msg_info "Setting up postgres database"
DATABASE_NAME='djangodb'
DATABASE_USER='djangouser'
DATABASE_PASSWORD='password'

sudo -u postgres psql -c "CREATE USER $DATABASE_USER WITH PASSWORD '$DATABASE_PASSWORD';" &>/dev/null
sudo -u postgres psql -c "CREATE DATABASE $DATABASE_NAME WITH OWNER $DATABASER_USERNAME;" &>/dev/null
sudo -u postgres psql -c "GRANTSTD ALL PRIVILEGES ON DATABASE $DATABASE_NAME TO $DATABASE_USER;" &>/dev/null

sudo -u postgres psql -c "ALTER ROLE $DATABASE_USER SET client_encoding TO 'utf8';" &>/dev/null
sudo -u postgres psql -c "ALTER ROLE $DATABASE_USER SET default_transaction_isolation TO 'read committed';" &>/dev/null
sudo -u postgres psql -c "ALTER ROLE $DATABASE_USER SET timezone TO 'UTC';" &>/dev/null

#--Grant superuser right to your new user, it will be removed later
#ALTER USER djangouser WITH SUPERUSER;

echo "" >>~/tandoor.creds
echo "Tandoor Recipes WebUI User" >>~/tandoor.creds
echo $DATABASE_USER >>~/tandoor.creds
echo "Tandoor Recipes WebUI Password" >>~/tandoor.creds
echo $DATABASE_PASSWORD >>~/tandoor.creds

cp /var/www/recipes/.env.template /var/www/recipes/.env
sed -i -e 's|^POSTGRES_USER=.*|POSTGRES_USER=$DATABASE_USER|' /var/www/recipes/.env
sed -i -e 's|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$DATABASE_PASS|' /var/www/recipes/.env
sed -i -e 's|^POSTGRES_DB=.*|POSTGRES_DB=$DATABASE_NAME|' /var/www/recipes/.env
SECRET_KEY="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)"
sed -i -e "s|^SECRET_KEY=.*|SECRET_KEY=$SECRET_KEY|" /var/www/recipes/.env

export $(cat /var/www/recipes/.env |grep "^[^#]" | xargs)
/bin/python3 manage.py migrate &>/dev/null
msg_ok "Set up postgres database"

msg_info "Configuring and starting gunicorn"
cat <<EOF > /etc/systemd/system/gunicorn_recipes.service
[Unit]
Description=gunicorn daemon for recipes
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=3
User=recipes
Group=www-data
WorkingDirectory=/var/www/recipes
EnvironmentFile=/var/www/recipes/.env
ExecStart=/var/www/recipes/bin/gunicorn --error-logfile /tmp/gunicorn_err.log --log-level debug --capture-output --bind unix:/var/www/recipes/recipes.sock recipes.wsgi:application

[Install]
WantedBy=multi-user.target
EOF
# Note: -error-logfile /tmp/gunicorn_err.log --log-level debug --capture-output are useful for debugging and can be removed later
# Note2: Fix the path in the ExecStart line to where you gunicorn and recipes are
sudo systemctl enable --now gunicorn_recipes
msg_ok "Configured and started gunicorn"

msg_info "Configuring and reloading nginx"
cat <<EOF > /etc/nginx/conf.d/recipes.conf
server {
    listen 8002;
    #access_log /var/log/nginx/access.log;
    #error_log /var/log/nginx/error.log;

    # serve media files
    location /static {
        alias /var/www/recipes/staticfiles;
    }

    location /media {
        alias /var/www/recipes/mediafiles;
    }

    location / {
        proxy_set_header Host $http_host;
        proxy_pass http://unix:/var/www/recipes/recipes.sock;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
sudo systemctl reload nginx
msg_ok "Configured and reloaded nginx"

msg_info "Installed Tandoor Recipes"

PASS=$(grep -w "root" /etc/shadow | cut -b6);
if [[ $PASS != $ ]]; then
msg_info "Customizing Container"
rm /etc/motd
rm /etc/update-motd.d/10-uname
touch ~/.hushlogin
GETTY_OVERRIDE="/etc/systemd/system/container-getty@1.service.d/override.conf"
mkdir -p $(dirname $GETTY_OVERRIDE)
cat << EOF > $GETTY_OVERRIDE
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
systemctl daemon-reload
systemctl restart $(basename $(dirname $GETTY_OVERRIDE) | sed 's/\.d//')
msg_ok "Customized Container"
fi
if [[ "${SSH_ROOT}" == "yes" ]]; then
  sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/g" /etc/ssh/sshd_config
  systemctl restart sshd
fi
msg_info "Cleaning up"
$STD apt-get autoremove
$STD apt-get autoclean
msg_ok "Cleaned"

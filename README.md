wget -O /tmp/setup-router.sh https://raw.githubusercontent.com/zhilmax/router-setup/main/setup-router.sh
chmod +x /tmp/setup-router.sh
/tmp/setup-router.sh

wget -O /tmp/prepare-for-client.sh https://raw.githubusercontent.com/zhilmax/router-setup/main/prepare-for-client.sh
chmod +x /tmp/prepare-for-client.sh
/tmp/prepare-for-client.sh

первая команда
wget -q -O /tmp/setup-router.sh https://raw.githubusercontent.com/zhilmax/router-setup/main/setup-router.sh && chmod +x /tmp/setup-router.sh && /tmp/setup-router.sh

вторая команда
wget -q -O /tmp/prepare-for-client.sh https://raw.githubusercontent.com/zhilmax/router-setup/main/prepare-for-client.sh && chmod +x /tmp/prepare-for-client.sh && /tmp/prepare-for-client.sh


одна общая команда
wget -q -O /tmp/router-setup.sh https://raw.githubusercontent.com/zhilmax/router-setup/main/router-setup.sh && chmod +x /tmp/router-setup.sh && /tmp/router-setup.sh

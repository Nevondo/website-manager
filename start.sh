#!/bin/bash

VER='1.7.0'
PHPVer='8.1'
_tmp="/tmp/answer.$$"
TITLE="Website Manager - Nevondo"

### Functions ###
function greenMessage {
    echo -e "\\033[32;1m${@}\033[0m"
}

function magentaMessage {
    echo -e "\\033[35;1m${@}\033[0m"
}

function cyanMessage {
    echo -e "\\033[36;1m${@}\033[0m"
}

function redMessage {
    echo -e "\\033[31;1m${@}\033[0m"
}

function yellowMessage {
    echo -e "\\033[33;1m${@}\033[0m"
}

function errorExit {
    redMessage ${@}
    exit 1
}

function installDialog {
    checkdialog=$(command -v dialog)

    if [[ $checkdialog = "" ]]; then
        greenMessage "Das Paket Dialog wird für dieses Skript benötigt und wird in 10 Sekunden installiert."
        sleep 1
        redMessage "Möchtest du das Paket nicht installieren, breche die Installation mit CTRL + C ab."
        sleep 10
        trap '' 2
        apt-get update
        apt-get install dialog -y
    fi

    # check for updates
    git pull --rebase
}

function checkRoot {
    if [ "$(id -u)" != "0" ]; then
        redMessage "Wechsle zu dem Root Benutzer!"
        su root
    fi
    if [ "$(id -u)" != "0" ]; then
        errorExit "Nicht als Rootbenutzer ausgeführt, Abgebrochen!"
        exit
    fi
}

function changePW {
    user=${@}
    pw=$(
        head /dev/urandom | tr -dc A-Za-z0-9 | head -c 15
        echo ''
    )

    echo "$user:$pw" | chpasswd

    clear
    echo "**************************"
    echo "User: $user"
    echo "Password: $pw"
    echo "**************************"

    exit 0
}

function removeDependencies {
    value=$1
    formattedValue=$(echo "$value" | sed -r 's/\.//g')
    rm /etc/php/"$PHPVer"/fpm/pool.d/"$formattedValue".conf
    rm /etc/nginx/sites-enabled/"$value"
    /usr/local/bin/certbot revoke --cert-path "/etc/letsencrypt/archive/$value/cert1.pem"
    rm -rf "/etc/letsencrypt/live/$value"
    rm -rf "/etc/letsencrypt/archive/$value"
    rm "/etc/letsencrypt/renewal/$value.conf"
}

function addPhp {
    domain=$1
    user=$2
    formatted=$(echo "$domain" | sed -r 's/\.//g')

    cp configs/pool.default /etc/php/"$PHPVer"/fpm/pool.d/"$formatted".conf
    sed -i "s/%DOMAIN%/$formatted/g" /etc/php/"$PHPVer"/fpm/pool.d/"$formatted".conf
    sed -i "s/%USER%/$user/g" /etc/php/"$PHPVer"/fpm/pool.d/"$formatted".conf
    sed -i "s/%PHPVERSION%/$PHPVer/g" /etc/php/"$PHPVer"/fpm/pool.d/"$formatted".conf

    sed -i '/### PHP START ###/r configs/php.template' /etc/nginx/sites-enabled/"$domain"
    sed -i "s/%PHPVERSION%/$PHPVer/g" /etc/nginx/sites-enabled/"$domain"
    sed -i "s/%FORMATTED%/$formatted/g" /etc/nginx/sites-enabled/"$domain"
    service php"$PHPVer"-fpm reload
}

function removePhp {
    domain=$1
    formatted=$(echo "$domain" | sed -r 's/\.//g')

    rm /etc/php/"$PHPVer"/fpm/pool.d/"$formatted".conf
    sed -i '/### PHP START ###/,/### PHP END ###/{//p;d;}' /etc/nginx/sites-enabled/"$domain"
    service php"$PHPVer"-fpm reload
}

### Menus ###
function execute_MainMenu {
    hash=$(git rev-parse --short HEAD 2>&1)
    dialog --backtitle "$TITLE" --title " Main Menu - v$VER ($hash)"\
    --cancel-label "Quit" \
    --menu "Move using [UP] [Down], [Enter] to select" 17 60 10\
    manageTLD "Manage TLDs"\
    quit "Exit Manager" 2>$_tmp

    opt=${?}
    if [ $opt != 0 ]; then
        rm $_tmp
        exit
    fi
    menuitem=$(cat $_tmp)
    case $menuitem in
    manageTLD) tld_menu ;;
    quit)
        rm $_tmp
        clear
        exit 0
        ;;
    esac
}

### TLD ###
function tld_menu {
    domains=""
    list="$(ls -G /var/www/vhost)"
    leer="-->"

    for d in $list; do
        domains="$domains $d $leer "
    done

    domains="$domains add $leer"

    dialog --backtitle "$TITLE" --title " Manage TLD-Domains " --cancel-label "Back" --menu "Move using [UP] [Down], [Enter] to select" 17 60 10 $domains 2>$_tmp
    website=$(cat $_tmp)
    if [[ $website != "add" && $website != "Back" ]]; then
        manageTld
    else
        if [[ $website == "add" ]]; then
            addTld
        else
            main_menu
        fi
    fi
}

function manageTld {
    formatted=$(echo "$website" | sed -r 's/\.//g')
    if [ -f "/etc/php/"$PHPVer"/fpm/pool.d/"$formatted".conf" ]; then
        phpStatus="Enabled"
    else
        phpStatus="Disabled"
    fi

    dialog --backtitle "$TITLE" --title " Manage TLD - $website"\
    --cancel-label "Back" \
    --menu "Move using [UP] [Down], [Enter] to select" 17 60 10\
    subdomains "Subdomains"\
    changePW "Reset password" \
    php "PHP [$phpStatus]"\
    delete "Delete"\
    back "Back" 2>$_tmp

    menuitem=$(cat $_tmp)
    case $menuitem in
    subdomains) subdomain_menu "$website" ;;
    changePW) changePW "www-$formatted" ;;
    php)
        if [[ $phpStatus == "Enabled" ]]; then
            removePhp "$website"
        else
            addPhp "$website" "$formatted"
        fi
        manageTld
        ;;
    delete) deleteTld "$website" ;;
    quit)
        rm $_tmp
        exit 0
        ;;
    esac
}

function addTld {
    domain=$(
        \
        dialog --title "Add TLD" \
        --cancel-label "Cancel" \
        --inputbox "Type in your TLD-Domain (example: domain.de)" 8 40 \
        \
        3>&1 1>&2 2>&3 3>&-
    )

    if [ -z "$domain" ]; then
        addTld
        exit 0
    fi
    clear

    if [ -d "/var/www/vhost/$domain/" ]; then
        errorExit "TLD already exits!"
    fi

    mkdir -p "/var/www/vhost/$domain/httpdocs/"
    mkdir -p "/var/www/vhost/$domain/logs/"
    formatted=$(echo "$domain" | sed -r 's/\.//g')

    pw=$(
        head /dev/urandom | tr -dc A-Za-z0-9 | head -c 15
        echo ''
    )
    useradd www-"$formatted" --home-dir "/var/www/vhost/$domain/" --no-create-home --shell /bin/nologin --password "$pw" --groups www-data

    cp configs/nginx-tld.default /etc/nginx/sites-enabled/"$domain"
    sed -i "s/%TLD%/$domain/g" /etc/nginx/sites-enabled/"$domain"
    sed -i "s/%DOMAIN%/$domain/g" /etc/nginx/sites-enabled/"$domain"
    sed -i "s/%FORMATTED%/$formatted/g" /etc/nginx/sites-enabled/"$domain"
    sed -i "s/%DIRECTORY%/httpdocs/g" /etc/nginx/sites-enabled/"$domain"

    /usr/local/bin/certbot certonly --webroot -w /var/www/letsencrypt/ -d "$domain" -d "www.$domain"
    service nginx reload

    cp configs/index.html "/var/www/vhost/$domain/httpdocs/index.html"
    sed -i "s/%DOMAIN%/$domain/g" "/var/www/vhost/$domain/httpdocs/index.html"
    chown root:root "/var/www/vhost/$domain/"
    chown -R www-"$formatted":www-data "/var/www/vhost/$domain/httpdocs/"
    chown -R www-"$formatted":root "/var/www/vhost/$domain/logs/"

    echo "**************************"
    echo "Domain: $domain"
    echo "User: www-$formatted"
    echo "Password: $pw"
    echo "**************************"

    exit 0
}

function deleteTld {
    domain=$1

    dialog --title "Delete TLD" --yesno "Remove $domain and all subdomains!?" 8 40
    response=$?

    if [ $response = 1 ]; then
        manageTld
        exit 0
    fi
    clear

    if [ -z "$domain" ]; then
        errorExit "No parameter!"
    fi

    if ! [ -d "/var/www/vhost/$domain/" ]; then
        errorExit "TLD doesn't exists!"
    fi

    tar cfz backups/$domain.tar.gz "/var/www/vhost/$domain/"

    list="$(ls -G /var/www/vhost/$domain/)"
    for subdomain in $list; do
        if [[ $subdomain != "httpdocs" ]] && [[ $subdomain != "logs" ]]; then
            rm -R "/var/www/vhost/$domain/$subdomain/"
            removeDependencies $subdomain
        fi
    done
    rm -R "/var/www/vhost/$domain/"
    removeDependencies $domain

    service php"$PHPVer"-fpm reload
    service nginx reload

    formatted=$(echo "$domain" | sed -r 's/\.//g')
    deluser www-"$formatted"

    echo "**************************"
    echo "Domain: $domain"
    echo "Status: DELETED"
    echo "Backup: backups/$domain.tar.gz"
    echo "**************************"

    exit 0
}

### Subdomain ###
function subdomain_menu {
    tld=$1
    domains=""
    list="$(ls -G /var/www/vhost/$tld/)"
    leer="-->"

    for d in $list; do
        if [[ $d != "httpdocs" ]] && [[ $d != "logs" ]]; then
            domains="$domains $d $leer "
        fi
    done

    domains="$domains add $leer"

    dialog --backtitle "$TITLE" --title " Manage Subdomains of $tld" --cancel-label "Back" --menu "Move using [UP] [Down], [Enter] to select" 17 60 10 $domains 2>$_tmp
    subdomain=$(cat $_tmp)
    if [[ $subdomain != "add" && $subdomain != "Back" ]]; then
        manageSubdomain "$tld" "$subdomain"
    else
        if [[ $subdomain == "add" ]]; then
            addSubdomain "$tld"
        else
            main_menu
        fi
    fi
}

function manageSubdomain {
    tld=$1
    subdomain=$2
    formattedSub=$(echo "$subdomain" | sed -r 's/\.//g')

    if [ -f "/etc/php/"$PHPVer"/fpm/pool.d/"$formattedSub".conf" ]; then
        phpStatus="Enabled"
    else
        phpStatus="Disabled"
    fi

    dialog --backtitle "$TITLE" --title " Manage Subdomain - $tld"\
    --cancel-label "Back" \
    --menu "Move using [UP] [Down], [Enter] to select" 17 60 10\
    php "PHP [$phpStatus]"\
    delete "Delete subdomain"\
    back "Back" 2>$_tmp

    menuitem=$(cat $_tmp)
    case $menuitem in
    php)
        if [[ $phpStatus == "Enabled" ]]; then
            removePhp "$subdomain"
        else
            addPhp "$subdomain" "$formattedSub"
        fi
        manageSubdomain "$tld" "$subdomain"
        ;;
    delete) deleteSubdomain "$tld" "$subdomain" ;;
    quit)
        rm $_tmp
        exit 0
        ;;
    esac
}

function addSubdomain {
    tld=$1

    subdomain=$(
        \
        dialog --title "Add Subdomain" \
        --cancel-label "Cancel" \
        --inputbox "Type in your Subdomain (example: subdomain.$tld)" 8 40 \
        \
        3>&1 1>&2 2>&3 3>&-
    )
    clear

    if [ -z "$subdomain" ]; then
        addSubdomain
        exit 0
    fi

    if [ -d "/var/www/vhost/$tld/$subdomain/" ]; then
        errorExit "Subdomain already exits!"
    fi

    mkdir -p "/var/www/vhost/$tld/$subdomain/"
    formattedSub=$(echo "$subdomain" | sed -r 's/\.//g')
    formattedTld=$(echo "$tld" | sed -r 's/\.//g')

    cp configs/nginx-subdomain.default /etc/nginx/sites-enabled/"$subdomain"
    sed -i "s/%TLD%/$tld/g" /etc/nginx/sites-enabled/"$subdomain"
    sed -i "s/%DOMAIN%/$subdomain/g" /etc/nginx/sites-enabled/"$subdomain"
    sed -i "s/%FORMATTED%/$formattedSub/g" /etc/nginx/sites-enabled/"$subdomain"
    sed -i "s/%DIRECTORY%/$subdomain/g" /etc/nginx/sites-enabled/"$subdomain"

    /usr/local/bin/certbot certonly --webroot -w /var/www/letsencrypt/ -d "$subdomain"
    service nginx reload

    cp configs/index.html "/var/www/vhost/$tld/$subdomain/index.html"
    sed -i "s/%DOMAIN%/$subdomain/g" "/var/www/vhost/$tld/$subdomain/index.html"
    chown -R www-"$formattedTld":www-data "/var/www/vhost/$tld/$subdomain/"

    echo "**************************"
    echo "TLD: $tld"
    echo "Subdomain: $subdomain"
    echo "User: www-$formattedTld"
    echo "**************************"

    exit 0
}

function deleteSubdomain {
    tld=$1
    subdomain=$2

    dialog --title "Delete Subdomain" --yesno "Remove $subdomain" 8 40
    response=$?

    if [ $response = 1 ]; then
        manageTLD
        exit 0
    fi
    clear

    if [ -z "$tld" ]; then
        errorExit "No parameter!"
    fi

    if ! [ -d "/var/www/vhost/$tld/$subdomain/" ]; then
        errorExit "Subdomain doesn't exists!"
    fi

    tar cfz backups/$subdomain.tar.gz "/var/www/vhost/$tld/$subdomain/"
    rm -R "/var/www/vhost/$tld/$subdomain/"
    removeDependencies $subdomain

    service php"$PHPVer"-fpm reload
    service nginx reload

    echo "**************************"
    echo "Domain: $subdomain"
    echo "Status: DELETED"
    echo "Backup: backups/$subdomain.tar.gz"
    echo "**************************"

    exit 0
}

### Main ###
checkRoot
installDialog

while true; do
    execute_MainMenu
done

#!/bin/bash
# Author: René Zingerle
# Thanks to: 
# - https://www.danballard.com/references/strongswan/www.zeitgeist.se/2013/11/22/strongswan-howto-create-your-own-vpn/index.html
# - https://wiki.strongswan.org/

# # #
# Check dependencies
check_dependencies() {

    # # #
    # Checks dependencies and tries to install them
    dep=("ipsec" "rsync")

    ni=0
    for x in "${dep[@]}"; do
        which $x &> /dev/null
        if [ $? -eq 1 ]; then
            echo "$x: is not installed"
            ni=$(($ni + 1))
        fi
    done
    return $ni
}
check_dependencies
if [ $? -gt 0 ]; then
    echo "The script found missing dependencies. Install them first."
    echo "http://blog.rothirsch.tech/server_farm/configurations/strongswan/#!install"
    exit 1
fi
#
# # #


# # #
# Create directories and get templates
cd $(dirname $0)
hdir="$PWD/"

# # #
# Read configuration
function readconfig {
    cat $2 | grep "$1" | awk -F": " '{print $NF}'
}
ca=$(readconfig "CA Name" "${hdir}CONFIGS/ca-infos")
ca_cert=$(readconfig "CA Certificate" "${hdir}CONFIGS/ca-infos")
ca_key=$(readconfig "CA Private Key" "${hdir}CONFIGS/ca-infos")
ca_name=$(readconfig "CA Full Name" "${hdir}CONFIGS/ca-infos")
ca_domain=$(readconfig "CA Domain" "${hdir}CONFIGS/ca-infos")

cert=${1##*/}
conf=${hdir}CONFIGS/${cert%.*}.configs
user_mail=$(readconfig "User Mail" "$conf")
user_name=$(readconfig "User Name" "$conf")
hosttype=$(readconfig "Hosttype" "$conf")


if [ -z $1 ]; then
    echo "Please provide a filename with path..."
    echo "For example: STORE/certs/test.domain.local.pem"
    exit 1
fi


if ! cat ${hdir}CONFIGS/ca-infos | grep "SSH Host"; then
    while ((i++)); read -r p 
    do
        echo [$i] $p
        sshhosts[$i]=$p
    done < <(cat ~/.ssh/config | grep ^Host | awk -F" " '{print $NF}')
    read -p "Choose IPSEC gateway in ~/.ssh/config for further use [0-9]: " dec
    ssh_host=${sshhosts[$dec]}
    echo "Storing SSH host ${sshhosts[$dec]} inside CONFIGS/ca-infos for later use"
    echo "SSH Host: ${sshhosts[$dec]}" >> ${hdir}CONFIGS/ca-infos

else
    ssh_host=$(readconfig "SSH Host" "${hdir}CONFIGS/ca-infos")

fi


# # #
# Synchronize to IPSEC gateway
if [ -f $1 ] && [[ "${1##*.}" == "pem" ]] && [[ ${1} =~ "STORE/certs/" ]]; then
    echo ""; echo "Synchronize certificate..."

    if [[ $hosttype =~ [vV] ]]; then
        file="STORE/private/${cert%.*}.pem"; echo "- SYNC: $file"; rsync -a ${hdir}$file ${ssh_host}:/etc/ipsec.d/private/
        if ! ssh ${ssh_host} cat /etc/ipsec.secrets |grep ${cert%.*}.pem &> /dev/null; then
            ssh ${ssh_host} "echo : RSA ${cert%.*}.pem >> /etc/ipsec.secrets"
        fi
    fi
    file="STORE/certs/${cert%.*}.pem"; echo "- SYNC: $file"; rsync -a ${hdir}$file ${ssh_host}:/etc/ipsec.d/certs/
    file="STORE/cacerts/ca.${ca_domain}_${ca}.pem"; echo "- SYNC: $file"; rsync -a ${hdir}$file ${ssh_host}:/etc/ipsec.d/cacerts/
    if [ -f STORE/crls/crl.${ca_domain}_${ca}.pem ]; then
        file="STORE/crls/crl.${ca_domain}_${ca}.pem"; echo "- SYNC: $file"; rsync -a ${hdir}$file ${ssh_host}:/etc/ipsec.d/crls/
    fi

    # # #
    # Synchronize to owncloud
    if [[ $hosttype =~ [uU] ]]; then
        if ! cat ${hdir}CONFIGS/ca-infos | grep "Owncloud Data"; then
            read -e -p "Owncloud root directory on $ssh_host: " ocroot
            echo "Owncloud Data: $ocroot" >> ${hdir}CONFIGS/ca-infos

        else
            ocroot=$(readconfig "Owncloud Data" "${hdir}CONFIGS/ca-infos")

        fi
        if ! cat $conf | grep "Owncloud User"; then
            read -e -p "Owncloud user on $ssh_host for $user_name: " ocuser
            echo "Owncloud User: $ocuser" >> $conf

        else
            ocuser=$(readconfig "Owncloud User" "$conf")

        fi
        ocdata="${ocroot}data/"
        conf=${hdir}CONFIGS/${cert%.*}.configs
        ssh ${ssh_host} "mkdir -p ${ocdata}${ocuser}/files/certificates/"
        file="../../../central/templates/README.md"; echo "- SYNC: $file"; rsync -a $file ${ssh_host}:${ocdata}${ocuser}/files/certificates/
        file="STORE/p12/${cert%.*}.p12"; echo "- SYNC: $file"; rsync -a $file ${ssh_host}:${ocdata}${ocuser}/files/certificates/
        ssh ${ssh_host} "chown -R www-data: $ocdata"
        ssh ${ssh_host} "cd $ocroot; sudo -u www-data php occ files:scan --all" 
    fi

else 
    echo $1
    echo "File does not exist or does not fill in the requierements."
fi

# # #
# Send mail
if [[ $hosttype =~ [uU] ]]; then

    echo ""; echo "Sending mail to user..."
    echo -e "\
    Hy $user_name,\n\
    \n\
    Your certificate has been transferred to the IPSEC Gateway\n\n\
    You can find the certificate inside your owncloud user account in the directory _certificates_\n\
    The certificate was transferred by ${ca_name}." | mail -s "[$(date +%d.%m.%y)] Certificate activated by ${ca_name}" -a "From: ca@$ca_domain" $user_mail
    
fi

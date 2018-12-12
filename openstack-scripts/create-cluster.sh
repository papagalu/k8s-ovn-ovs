#!/bin/bash

set -e
set -x

set -o pipefail

declare -a WINDOWS_NODES
declare -a LINUX_NODES

CONFIG="/etc/k8s-ovn-ovs/config.ini"
OPENSTACK_ADMIN="/etc/k8s-ovn-ovs/admin-openrc.sh"

WINDOWS_USER_DATA=""
LINUX_USER_DATA=""

PRIVATE_KEY=""
KEY_NAME=""

WINDOWS_FLAVOR=""
LINUX_FLAVOR=""

WINDOWS_IMAGE=""
LINUX_IMAGE=""

NETWORK_INTERNAL=""
NETWORK_EXTERNAL=""

ANSIBLE_MASTER=""
ANSIBLE_SERVER=""
ANSIBLE_USER_DATA=""

REPORT_FILE=""

KUBERNETES_REMOTE=""
KUBERNETES_COMMIT=""

function read-config() {
    local config="$1"

    IFS=$","
    WINDOWS=$(crudini --get $config windows server-names)
    LINUX=$(crudini --get $config linux server-names)
    WINDOWS_NODES=($WINDOWS)
    LINUX_NODES=($LINUX)
    IFS=$" "

    WINDOWS_USER_DATA=$(crudini --get $config windows user-data)
    LINUX_USER_DATA=$(crudini --get $config linux user-data)

    WINDOWS_FLAVOR=$(crudini --get $config windows flavor)
    LINUX_FLAVOR=$(crudini --get $config linux flavor)

    WINDOWS_IMAGE=$(crudini --get $config windows image)
    LINUX_IMAGE=$(crudini --get $config linux image)
    
    PRIVATE_KEY=$(crudini --get $config keys private)
    KEY_NAME=$(crudini --get $config keys name)

    NETWORK_INTERNAL=$(crudini --get $config network internal)
    NETWORK_EXTERNAL=$(crudini --get $config network external)

    ANSIBLE_SERVER=$(crudini --get $config ansible server-name)
    ANSIBLE_USER_DATA=$(crudini --get $config ansible user-data)

    REPORT_FILE=$(crudini --get $config report file-path)

    KUBERNETES_REMOTE=$(crudini --get $config kubernetes noremote)
    KUBERNETES_COMMIT=$(crudini --get $config kubernetes commit)

    echo "CONFIG IS:"
    echo "----------------------------------------------"
    echo "Windows nodes are:        ${WINDOWS_NODES[@]}"
    echo "Windows user data script: $WINDOWS_USER_DATA"
    echo "Windows flavor:           $WINDOWS_FLAVOR"
    echo "Windows image:            $WINDOWS_IMAGE"
    echo "----------------------------------------------"
    echo "Linux nodes are:          ${LINUX_NODES[@]}"
    echo "Linux user data script:   $LINUX_USER_DATA"
    echo "Linux flavor:             $LINUX_FLAVOR"
    echo "Linux image:              $LINUX_IMAGE"
    echo "----------------------------------------------"
    echo "Private key: $PRIVATE_KEY"
    echo "----------------------------------------------"
}

function delete-instance () {
    local server="$1"

    echo "Now deleting : $server"
    exist=$(openstack server list | grep $server | wc -l) || true
    if [[ ! $exist -eq 0 ]]; then
        ip=$(openstack server show $server | grep address | awk '{print $5}')
        openstack floating ip delete $ip || true
        openstack server delete "$server"
    fi
}

function delete-previous-cluster () {
    for server in ${WINDOWS_NODES[@]}; do
        delete-instance $server
    done
    for server in ${LINUX_NODES[@]}; do
        delete-instance $server
    done
    if [[ "$ANSIBLE_MASTER" == "true" ]]; then
        delete-instance $ANSIBLE_SERVER
    fi
}

function boot-instance () {
    local server="$1";   shift
    local platform="$1"; shift
    local custom_platform_flavor="$1"

    local flavor=$(eval echo "\$${platform}_FLAVOR")
    local image=$(eval echo "\$${platform}_IMAGE")
    local user_data=$(eval echo "\$${platform}_USER_DATA")

    echo "Now booting : $server"
    nova boot --flavor $flavor --image $image --nic net-id=$NETWORK_INTERNAL --key $KEY_NAME --user-data $user_data $server > /dev/null
    while true; do
        stat=$(openstack server list | grep $server | awk '{print $6}')
        if [[ ! "$stat" == "ACTIVE" ]]; then
            sleep 3
        elif [[ "$stat" == "ERROR" ]]; then
            echo "$server is in ERROR state."
            exit 1
        else
            break
        fi
    done
}

function boot-ansible () {
    if [[ "$ANSIBLE_MASTER" == "true" ]]; then
        echo "Booting Ansible master"
        nova boot --flavor $WINDOWS_FLAVOR --image $LINUX_IMAGE --nic net-id=$NETWORK_INTERNAL --key $KEY_NAME --user-data $ANSIBLE_USER_DATA $ANSIBLE_SERVER > /dev/null
        ip=$(openstack floating ip create $NETWORK_EXTERNAL | grep " name " | awk '{print $4}')
        openstack server add floating ip $ANSIBLE_SERVER $ip
    fi
}

function create-cluster () {
    for server in ${WINDOWS_NODES[@]}; do
        boot-instance $server "WINDOWS"
    done
    for server in ${LINUX_NODES[@]}; do
        boot-instance $server "LINUX"
    done
    boot-ansible
}

function wait-windows-nodes () {
    echo "Waiting for windows nodes to get password"

    for server in ${WINDOWS_NODES[@]}; do
        while true; do
            pass=$(nova get-password $server $PRIVATE_KEY)
            if [[ -z $pass ]]; then
                sleep 5
            else
                break
            fi
        done
    done
}

function generate-report () {
    local report="$1"; shift
    local password="$1"

    declare -a ips_linux
    declare -a ips_windows
    declare -a passwords

    for server in ${WINDOWS_NODES[@]}; do
        ip=$(openstack server show $server | grep address | awk '{print $4}'); ip=${ip#*=}; ip=${ip%,}
        ips_windows+=($ip)
        pass=$(nova get-password $server $PRIVATE_KEY)
        passwords+=($pass)
    done
    for server in ${LINUX_NODES[@]}; do
        ip=$(openstack server show $server | grep address | awk '{print $4}'); ip=${ip#*=}; ip=${ip%,}
        ips_linux+=($ip)
    done

    IFS=","
    crudini --set $report linux server-names "${LINUX_NODES[*]}"
    crudini --set $report windows server-names "${WINDOWS_NODES[*]}"

    crudini --set $report linux ips "${ips_linux[*]}"
    crudini --set $report windows ips "${ips_windows[*]}"
    crudini --set $report windows passwords "${passwords[*]}"

    crudini --set $report linux ssh-key "~/id_rsa" # remote location of ssh key

    crudini --set $report kubernetes noremote $KUBERNETES_REMOTE
    crudini --set $report kubernetes commit $KUBERNETES_COMMIT
    IFS=$" "
}

function prepare-ansible-node () {
    local report="$1";
    local report_name=$(basename $report)

    local ip=$(openstack server show $ANSIBLE_SERVER | grep address | awk '{print $5}')
    sleep 15 # sleep till node becomes available
    ssh-keyscan -H $ip >> ~/.ssh/known_hosts

    scp -i $PRIVATE_KEY $PRIVATE_KEY $ip:~/
    scp -i $PRIVATE_KEY $report $ip:~/
    ssh -i $PRIVATE_KEY $ip "cat | bash /dev/stdin --report ~/$report" < ansible-script.sh
}

function prepare-tests () {
    local ansible_ip=$(openstack server show $ANSIBLE_SERVER | grep address | awk '{print $5}')
    local master_ip=$(openstack server show ${LINUX_NODES[0]} | grep address | awk '{print $4}'); master_ip=${master_ip#*=}; master_ip=${master_ip%,}

    scp -i $PRIVATE_KEY -r run-e2e/ $ansible_ip:~/
    ssh -i $PRIVATE_KEY $ansible_ip "cat | bash /dev/stdin --k8s-master-ip $master_ip \
        --id-rsa ~/id_rsa --linux-node ${LINUX_NODES[1]}" < prepare-tests.sh
}

function main() {
    TEMP=$(getopt -o c:x::d::a::b: --long config:,down::,up::,test::,admin-openrc: -n '' -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    echo $TEMP
    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            --config)
                CONFIG="$2";             shift 2;;
            --down)
                DOWN="true";             shift 2;;
            --up)
                UP="true";               shift 2;;
            --test)
                TEST="true";             shift 2;;
            --admin-openrc)
                OPENSTACK_ADMIN="$2"
                source $OPENSTACK_ADMIN; shift 2;;
            --) shift ; break ;;
        esac
    done

    read-config "$CONFIG"
    delete-previous-cluster
    if [[ $DOWN == "true" ]]; then
        exit 0
    fi
    if [[ $UP == "true" ]]; then
        create-cluster
        wait-windows-nodes
        generate-report "$REPORT_FILE"
        prepare-ansible-node "$REPORT_FILE"
    fi
    if [[ $TEST == "true" ]]; then
        prepare-tests
    fi

}

main "$@"

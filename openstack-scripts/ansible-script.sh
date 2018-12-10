#!/bin/bash

set -e
set -x

set -o pipefail

declare -a LINUX_NODES
declare -a WINDOWS_NODES

declare -a LINUX_IP
declare -a WINDOWS_IP

declare -a PASSWORDS

PRIVATE_KEY=""

KUBERNETES_REMOTE=""
KUBERNETES_COMMIT=""

function wait-user-data () {
    echo "Waiting for crudini to be available"
    while true; do
        x=$(which crudini || true)
        if [[ -z $x ]]; then
            sleep 5
        else
            break
        fi
    done
}

function read-report () {
    local report="$1"

    echo "Reading report"
    IFS=$","
    WINDOWS=$(crudini --get $report windows server-names)
    LINUX=$(crudini --get $report linux server-names)
    WINDOWS_NODES=($WINDOWS)
    LINUX_NODES=($LINUX)

    WINDOWS=$(crudini --get $report windows ips)
    LINUX=$(crudini --get $report linux ips)
    WINDOWS_IP=($WINDOWS)
    LINUX_IP=($LINUX)

    WINDOWS=$(crudini --get $report windows passwords)
    PASSWORDS=($WINDOWS)

    KUBERNETES_REMOTE=$(crudini --get $report kubernetes noremote)
    KUBERNETES_COMMIT=$(crudini --get $report kubernetes commit)

    IFS=$" "
}

function clone-repo () {
    local repo="$1"; shift
    local destination="$1"

    echo "Cloning repo"
    if [[ ! -d "$destination" ]]; then
        git clone $repo "$destination"
        pushd "$destination"
            git checkout diff_download
        popd
    fi
}
 
function populate-etc-hosts () {
    local length_linux=${#LINUX_NODES[@]}
    local length_windows=${#WINDOWS_NODES[@]}

    echo "Populating /etc/hosts"
    for (( i=0; i < $length_linux; i++ )); do
        printf "%s %s\n" "${LINUX_IP[$i]}" "${LINUX_NODES[$i]}" | sudo tee -a /etc/hosts
    done
    for (( i=0; i < $length_windows; i++ )); do
        printf "%s %s\n" "${WINDOWS_IP[$i]}" "${WINDOWS_NODES[$i]}" | sudo tee -a /etc/hosts
    done
}

function populate-ansible-hosts () {
    local file="$1"

    echo "Populating ansible invetory hosts"
    sed -i "s/node.//g" "$file"
    let i=1
    for server in ${LINUX_NODES[@]}; do
        if [[ $i == "1" ]]; then
            sed -i "/\[kube-master\]/a $server" "$file"
        else
            sed -i "/\[kube-minions-linux\]/a $server" "$file"
        fi
        i=$((i + 1))
    done
    for server in ${WINDOWS_NODES[@]}; do
        sed -i "/\[kube-minions-windows\]/a $server" "$file"
    done
}

function enable-ansible-log () {
    pushd ~/ovn-kubernetes/contrib
        echo "log_path=~/ansible.log" >> ansible.cfg
    popd
}

function configure-linux-connection () {
    local file_master="$1"; shift
    local file_minions="$1"

    echo "Configure ansible to use ssh key for linux minions"
    sed -i "/ubuntu/a ansible_ssh_private_key_file: ~\/id_rsa" $file_master
    sed -i "/ubuntu/a ansible_ssh_private_key_file: ~\/id_rsa" $file_minions
}

function create-windows-login-file () {
    local template='ansible_user: admin\nansible_password: %s'

    echo "Creating individual file for windows minions(winrm)"
    length=${#WINDOWS_NODES[@]}
    for (( i=0; i < $length; i++ )); do
        printf "$template" ${PASSWORDS[$i]} > "ovn-kubernetes/contrib/inventory/host_vars/${WINDOWS_NODES[$i]}"
    done
}

function ssh-key-scan () {
    echo "ssh keyscan for linux minions"
    for server in ${LINUX_NODES[@]}; do
        ssh-keyscan $server >> ~/.ssh/known_hosts
        sudo bash -c "ssh-keyscan $server >> /root/.ssh/known_hosts"
    done
}

function install-go () {
    echo "Installing golang"

    pushd /tmp
        if [[ ! -f go1.11.1.linux-amd64.tar.gz ]]; then
            wget https://dl.google.com/go/go1.11.1.linux-amd64.tar.gz
            tar -xf go1.11.1.linux-amd64.tar.gz
            sudo mv go /usr/lib
        fi
    popd

    mkdir -p $HOME/go/{bin,pkg,src}

    local template="""
export GOROOT=/usr/lib/go
export GOBIN=/usr/lib/go/bin
export GOPATH=/home/ubuntu/go
export PATH=/usr/lib/go/bin:$PATH:/home/ubuntu/go/bin;
"""
    echo $template >> ~/.bashrc
}

function install-docker () {
   echo "Installing docker"
   DEBIAN_FRONTEND=noninteractive sudo apt-get install docker.io -y

   echo "Adding user $USER to docker group"
   sudo usermod -a -G docker $USER
}

function build-k8s-binaries () {
    set -x
    sudo apt-get install apache2 -y

    source ~/.bashrc
    export GOROOT=/usr/lib/go
    export GOBIN=/usr/lib/go/bin
    export GOPATH=/home/ubuntu/go
    export PATH=/home/ubuntu/bin:/usr/lib/go/bin:$PATH:/home/ubuntu/go/bin

    mkdir -p ~/go/src/k8s.io
    pushd ~/go/src/k8s.io
        if [[ ! -d kubernetes ]]; then
            git clone "https://github.com/$KUBERNETES_REMOTE/kubernetes"
            pushd kubernetes
                git checkout $KUBERNETES_COMMIT
            popd
        fi
    popd

    pushd $GOPATH/src/k8s.io/kubernetes
        sudo ./build/run.sh make WHAT="cmd/kube-apiserver cmd/kube-controller-manager cmd/kubelet cmd/kubectl cmd/kube-scheduler"
        sudo ./build/run.sh make WHAT="cmd/kubelet cmd/kubectl" KUBE_BUILD_PLATFORMS=windows/amd64

        mkdir -p ~/ovn-kubernetes/contrib/tmp
        cp _output/dockerized/bin/windows/amd64/*.exe  ~/ovn-kubernetes/contrib/tmp
        cp _output/dockerized/bin/linux/amd64/kube*  ~/ovn-kubernetes/contrib/tmp

        sudo cp _output/dockerized/bin/linux/amd64/kubectl  /usr/bin
    popd
}

function deploy-k8s-cluster () {
    echo "starting kubernetes deployment"
    sudo cp /home/ubuntu/id_rsa /root/
    pushd "ovn-kubernetes/contrib"
        while true; do
            if ansible -m setup all > /dev/null; then
                break
            else 
                sleep 5
            fi
        done
        sudo bash -c "ansible-playbook ovn-kubernetes-cluster.yml -vv"
    popd
}

function restart-ovn-watcher () {
    ssh -i ~/id_rsa ${LINUX_NODES[0]} "sudo systemctl restart ovn-k8s-watcher"
}

function main () {
    TEMP=$(getopt -o r: --long report: -n 'ansible-script.sh' -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    echo $TEMP
    eval set -- "$TEMP"

    while true ; do
        case "$1" in
            --report)
                report="$2";           shift 2;;
            --) shift ; break ;;
        esac
    done

    wait-user-data
    read-report "$report"
    clone-repo "https://github.com/papagalu/ovn-kubernetes.git" "./ovn-kubernetes"
    populate-etc-hosts
    populate-ansible-hosts "./ovn-kubernetes/contrib/inventory/hosts"
    enable-ansible-log
    configure-linux-connection "./ovn-kubernetes/contrib/inventory/group_vars/kube-master" \
        "./ovn-kubernetes/contrib/inventory/group_vars/kube-minions-linux"
    create-windows-login-file
    ssh-key-scan
    install-go
    install-docker
    build-k8s-binaries
    deploy-k8s-cluster
    restart-ovn-watcher
}

main "$@"

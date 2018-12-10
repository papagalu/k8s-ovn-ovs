#!/bin/bash

set -e
set -x

set -o pipefail

K8S_MASTER_IP=""
ID_RSA=""
LINUX_NODE=""

function configure-kubectl () {
    mkdir -p scp
    ssh -i $ID_RSA $K8S_MASTER_IP mkdir -p ~/scp
    ssh -i $ID_RSA $K8S_MASTER_IP sudo cp -r /etc/kubernetes/* ~/scp
    ssh -i $ID_RSA $K8S_MASTER_IP sudo cp /root/.kube/config ~/scp
    ssh -i $ID_RSA $K8S_MASTER_IP sudo chown -R ubuntu:ubuntu ~/scp
    scp -r -i $ID_RSA $K8S_MASTER_IP:~/scp/* scp/

    mkdir -p ~/.kube
    sudo mkdir -p /etc/kubernetes/tls

    cp ~/scp/config ~/.kube/
    sudo cp ~/scp/tls/* /etc/kubernetes/tls
    sudo chmod 0644 /etc/kubernetes/tls/*
}

function program-is-installed () {
    local return_=1
    type $1 >/dev/null 2>&1 || { local return_=0; }
    echo "$return_"
}

function build-k8s-parts () {
    pushd ~/go/src/k8s.io/kubernetes
        git checkout master --force
        sudo ./build/run.sh make WHAT="test/e2e/e2e.test vendor/github.com/onsi/ginkgo/ginkgo"
    popd
}

function get-kubetest () {
    source ~/.bashrc
    export GOROOT=/usr/lib/go
    export GOBIN=/usr/lib/go/bin
    export GOPATH=/home/ubuntu/go
    export PATH=/home/ubuntu/bin:/usr/lib/go/bin:$PATH:/home/ubuntu/go/bin
    go get -u k8s.io/test-infra/kubetest
}

function populate-kube-env () {
    sed -i "s/KUBE_MASTER=/&local/" run-e2e/kube-env
    sed -i "s/KUBE_MASTER_IP=/&$K8S_MASTER_IP/" run-e2e/kube-env
    sed -i "s/KUBE_MASTER_URL=/&https:\/\/$K8S_MASTER_IP/" run-e2e/kube-env
    sed -i "s/KUBECONFIG=/&\/home\/ubuntu\/.kube\/config/" run-e2e/kube-env
    sed -i "s/KUBE_TEST_REPO_LIST=/&\/home\/ubuntu\/run-e2e\/repo-list.yaml/" run-e2e/kube-env
}

function taint-node () {
    kubectl taint nodes $LINUX_NODE key=value:NoSchedule
    kubectl label nodes linux1 node-role.kubernetes.io/master=NoSchedule
}

function start-tests () {
    pushd run-e2e
        set -x
        source kube-env
        focus=$(cat focus | sed 's:\\\\:\\:g')
        skip=$(cat skip | sed 's:\\\\:\\:g')
        mkdir -p results
        pushd ~/go/src/k8s.io/kubernetes
            # apply custom commits
            git remote add e2e-win https://github.com/e2e-win/kubernetes
            git fetch e2e-win
            git cherry-pick -n cb68f5ef9990dd93d6db719cd17ee8b7cbf2f5d4

            kubetest --ginkgo-parallel=4 --verbose-commands=true --provider=local --test \
                --test_args="--ginkgo.dryRun=false --ginkgo.focus=$focus --ginkgo.skip=$skip" --dump=~/run-e2e/results/ \
                | tee ~/run-e2e/results/kubetest.log
        popd
    popd
}

function main () {
    TEMP=$(getopt -o i:k:d: --long k8s-master-ip:,id-rsa:,linux-node: -n '' -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    echo $TEMP
    eval set -- "$TEMP"
    
    while true ; do
        case "$1" in
            --k8s-master-ip)
                K8S_MASTER_IP="$2";    shift 2;;
            --id-rsa)
                ID_RSA="$2";           shift 2;;
            --linux-node)
                LINUX_NODE="$2";       shift 2;;
            --) shift ; break ;;
        esac
    done

    configure-kubectl
    build-k8s-parts
    get-kubetest
    populate-kube-env
    taint-node
    start-tests
}

main "$@"

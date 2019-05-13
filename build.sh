#!/bin/bash -e

CONFIG_DIR=$(dirname $(realpath $0))

export COREOS_ASSEMBLER_CONFIG_GIT=${CONFIG_DIR}
export COREOS_ASSEMBLER_CONTAINER=localhost/coreos-assembler

setup_repos() {
    local ovirt_release_rpm="$1"
    local fedora_release="$2"

    pushd $CONFIG_DIR
    # Grab basic fedora-coreos-config
    git clone --depth=1 https://github.com/coreos/fedora-coreos-config.git
    ln -sf fedora-coreos-config/*.repo .
    ln -sf fedora-coreos-config/minimal.yaml .

    # Extract repo files from release.rpm
    tmpdir=$(mktemp -d)
    curl -L -o "${tmpdir}/release.rpm" ${ovirt_release_rpm}
    rpm2cpio "${tmpdir}/release.rpm" | cpio -divuD ${tmpdir}
    rpm -qp --qf "%{POSTIN}" "${tmpdir}/release.rpm" | \
        sed "s#\"/#\"/${tmpdir}/#g" > "${tmpdir}/postin.sh"
    mkdir -p "${tmpdir}/etc/yum.repos.d"
    bash -e "${tmpdir}/postin.sh"
    cp ${tmpdir}/etc/yum.repos.d/*.repo .
    rm -rf ${tmpdir}

    # Generate ovirt-node-config
    sed "s/@FC_RELEASE_VER@/${fedora_release}/" ovirt-coreos-base.yaml.in > ovirt-coreos-base.yaml
    echo "repos:" >> ovirt-coreos-base.yaml
    grep '^\[' *.repo | \
        cut -d: -f2 | \
        sed 's/\[\(.*\)\]/  - \1/' >> ovirt-coreos-base.yaml
    popd
}

setup_cosa() {
    if [[ -z ${COREOS_ASSEMBLER_CONTAINER} ]]; then
        podman pull quay.io/coreos-assembler/coreos-assembler:latest
    fi

    if [ ! -d srv-coreos ]
    then
        mkdir srv-coreos
        setfacl -m u:1000:rwx srv-coreos
        setfacl -d -m u:1000:rwx srv-coreos
        chcon system_u:object_r:container_file_t:s0 srv-coreos
        mkdir -p srv-coreos/overrides/rpm
        [[ -d overrides ]] && cp overrides/*.rpm srv-coreos/overrides/rpm
    fi

    cd srv-coreos
}

cosa() {
    env | grep COREOS_ASSEMBLER

    podman run --rm -ti -v ${PWD}:/srv/ --userns=host --device /dev/kvm --name cosak \
        ${COREOS_ASSEMBLER_PRIVILEGED:+--privileged}                                          \
        ${COREOS_ASSEMBLER_CONFIG_GIT:+-v $COREOS_ASSEMBLER_CONFIG_GIT:/srv/src/config/:ro}   \
        ${COREOS_ASSEMBLER_GIT:+-v $COREOS_ASSEMBLER_GIT/src/:/usr/lib/coreos-assembler/:ro}  \
        ${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS}                                            \
        ${COREOS_ASSEMBLER_CONTAINER:-quay.io/coreos-assembler/coreos-assembler:latest} $@

    return $?
}

main() {
    local ovirt_release_rpm=""
    local fedora_release=""

    while getopts "r:v:" OPTION
    do
        case $OPTION in
            r)
                ovirt_release_rpm=$OPTARG
                ;;
            v)
                fedora_release=$OPTARG
                ;;
        esac
    done

    if [[ -n ${ovirt_release_rpm} && -n ${fedora_release} ]]; then
        echo "Using ovirt-release-rpm: ${ovirt_release_rpm}"
        echo "Using Fedora: ${fedora_release}"
        setup_repos "${ovirt_release_rpm}" "${fedora_release}"
        setup_cosa
        cosa init --force /dev/null
        cosa fetch
        cosa build
    fi
}

main "$@"

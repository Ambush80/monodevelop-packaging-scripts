#!/bin/bash

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
rm "${DIR}/build.log"
exec >  >(tee -a ${DIR}/build.log)
exec 2> >(tee -a ${DIR}/build.log>&2)

TYPE=$1
# TODO
# - Get version based on monodevelop_dir or write it
# - Fixup dpkg build step

function setup_prereqs()
{
    sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF || exit 1
    sudo rm /etc/apt/sources.list.d/mono-xamarin.list
    echo "deb http://download.mono-project.com/repo/debian wheezy main" | sudo tee /etc/apt/sources.list.d/mono-xamarin.list
    echo "deb http://download.mono-project.com/repo/debian wheezy-apache24-compat main" | sudo tee -a /etc/apt/sources.list.d/mono-xamarin.list
    sudo apt-get update || exit 1
    sudo apt-get install gtk-sharp2 mono-devel zlib1g-dev libmono-addins0.2-cil monodoc-base cmake libssh2-1-dev automake fsharp intltool gnome-sharp2 git referenceassemblies-pcl devscripts git-buildpackage pbuilder || exit 1

    rm "${HOME}/.pbuilderrc"

    cat <<-__EOF__ > "${HOME}/.pbuilderrc"
## Overrides /etc/pbuilderrc
DISTRIBUTION=trusty
COMPONENTS="main restricted universe multiverse"
BUILDRESULT=${RESULT_DIR}
# Hooks for chroot environment
HOOKDIR=${HOOK_DIR}
# Mount directories inside chroot environment
BINDMOUNTS=\${BUILDRESULT}
# Bash prompt inside pbuilder
export debian_chroot="pbuild\$$"
# For D70results hook
export LOCALREPO=\${BUILDRESULT}
__EOF__

    mkdir -p ${RESULT_DIR}
    mkdir -p ${HOOK_DIR}
    cat <<-'__EOF__' > ${HOOK_DIR}/D70results
#!/bin/sh
echo "Executing hook: $0"
cd ${LOCALREPO}
dpkg-scanpackages . /dev/null > Packages
echo "deb file:${LOCALREPO} ./" >> /etc/apt/sources.list
apt-get update
__EOF__
    chmod +x ${HOOK_DIR}/D70results

    cat <<-'__EOF__' > ${HOOK_DIR}/D10add_xamarin
#!/bin/sh

echo "Adding Xamarin sources"
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF
echo "deb http://download.mono-project.com/repo/debian wheezy main" | tee /etc/apt/sources.list.d/mono-xamarin.list
echo "deb http://download.mono-project.com/repo/debian wheezy-apache24-compat main" | tee -a /etc/apt/sources.list.d/mono-xamarin.list
apt-get update
__EOF__
    chmod +x ${HOOK_DIR}/D10add_xamarin

    sudo pbuilder create --debootstrapopts --variant=buildd || exit 1

}

function setup_env()
{
    MD_VERSIONS=($(git ls-remote --tags https://github.com/mono/monodevelop.git | grep monodevelop- | sort -t '/' -k 3 -V | grep -v {} | cut -d"/" -f 3))
    MONODEVELOP_DIR="${DIR}/monodevelop"
    PACKAGING_DIR="${DIR}/linux-packaging-monodevelop"
    TAG_NAME="${MD_VERSIONS[-1]}"
    LONG_VERSION=$(echo ${TAG_NAME} | cut -d"-" -f2)
    VERSION=$(echo ${LONG_VERSION} | cut -d"." -f1,2)
    NEWTARBALL="${MONODEVELOP_DIR}/tarballs/monodevelop-${VERSION}.tar.bz2"
    HOOK_DIR="${HOME}/pbuilder/hook"
    RESULT_DIR="${HOME}/pbuilder/result"

    if [[ "x${VERSION}" == "x" ]]
    then
        exit 1
    fi

    ARTIFACTS_PATH="${DIR}/artifacts/${LONG_VERSION}"
    mkdir -p "${ARTIFACTS_PATH}"

    echo "Version: ${LONG_VERSION}"
}

function build_md_dist()
{
    if [ -d "${MONODEVELOP_DIR}" ]
    then
        rm -rf "${MONODEVELOP_DIR}"
    fi

    if [ -z ${MONODEVELOP_REPO_URL} ]
    then
        MONODEVELOP_REPO_URL="https://github.com/mono/monodevelop.git"
    else
        echo "Using provided Git address: ${MONODEVELOP_REPO_URL}"
    fi

    git clone --branch ${TAG_NAME} --depth 1 ${MONODEVELOP_REPO_URL} "${MONODEVELOP_DIR}" || exit 1
    pushd "${MONODEVELOP_DIR}"
    git clean -xdf || exit 1
    git reset --hard HEAD || exit 1
    ./configure --profile default || exit 1
    make dist || exit 1
    popd
}

function build_dsc()
{
    if [ -d "${PACKAGING_DIR}" ]
    then
        rm -rf "${PACKAGING_DIR}"
    fi

    if [ -z ${LINUX_PACKAGING_MONODEVELOP_URL} ]
    then
        LINUX_PACKAGING_MONODEVELOP_URL="https://github.com/mono/linux-packaging-monodevelop.git"
    else
        echo "Using provided Git address: ${LINUX_PACKAGING_MONODEVELOP_URL}"
    fi

    git clone ${LINUX_PACKAGING_MONODEVELOP_URL} "${PACKAGING_DIR}"  || exit 1
    pushd "${PACKAGING_DIR}"
    git checkout -t origin/upstream || exit 1
    git checkout -t origin/pristine-tar || exit 1
    git checkout master || exit 1
    OLDVER=`dpkg-parsechangelog | grep Version | awk '{print \$2}' | cut -f1 -d'-'`
    NEWVER=`basename ${NEWTARBALL} | cut -f2 -d'-' | sed 's/\.tar\.bz2//'`
    echo "Old: ${OLDVER}"
    echo "New: ${NEWVER}"
    if [ "${OLDVER}" = "${NEWVER}" ]
    then
        echo "MATCHES"
        DCHCOMMAND="-l xamarin \"Bugfix - see git log\""
        ORIG=`pristine-tar list | grep monodevelop_${NEWVER}\.orig\.tar`
        pristine-tar checkout ${ORIG} || exit 1
        mv monodevelop_${NEWVER}.orig* .. || exit 1
    else
        DCHCOMMAND="-v ${NEWVER}-0xamarin1 \"New release - `basename ${NEWTARBALL}`\""
        DEBUILDCOMMAND="-sa"
        gbp import-orig --pristine-tar --no-merge --no-interactive ${NEWTARBALL} || exit 1
        git merge --strategy-option theirs upstream || exit 1
    fi

    dch --distribution=${BRANCH} --force-distribution ${DCHCOMMAND}
    git add debian/changelog || exit 1
    git commit -m "finalize changelog" || exit 1
    gbp buildpackage --git-ignore-new --git-tag-only --git-cleaner=/bin/true || exit 1
    debuild -nc -S ${DEBUILDCOMMAND} || exit 1
    mv ../monodevelop_* "${ARTIFACTS_PATH}" || exit 1
    popd
}

function build_dpkg()
{
    sudo pbuilder build "${ARTIFACTS_PATH}"/*.dsc
}

case $TYPE in
    setup)
        setup_env
        setup_prereqs
        ;;

    all)
        setup_env
        build_md_dist
        build_dsc
        build_dpkg
        ;;

    dist)
        setup_env
        build_md_dist
        ;;

    dsc)
        setup_env
        build_dsc
        ;;

    dpkg)
        setup_env
        build_dpkg
        ;;
    *)
        exit 1
        ;;
esac



#!/bin/bash

function mkchroot {

 # just in case we don't inherit.
 if [[ -z "${FUNCNAME}" ]];
 then
  FUNCNAME='mkchroot-standalone'
 fi
 
 ## Import settings
 if [ -f "build.conf" ];
 then
  echo "Now importing settings/variables."
  set -e
  source build.conf
  set +e
 else
  echo "You have not configured a build.conf OR you are not running from the project's root directory (the git repository's working directory)."
  echo "If you are indeed in the correct directory, you may copy the sample at ../extra/build.conf.sample,"
  echo "edit it for appropriate values, and copy to <PROJECT ROOT>/build.conf"
  echo 'This error is fatal. Dying.'
  exit 1
 fi
 
 if [[ ${EUID} -ne 0 ]];
 then
   #echo "This script must be run as root" 1>&2
   echo "This script must be run as root."
   exit 1
 fi
 
 if [ -z "${BASEDIR}" ];
 then
  echo 'You need to export the directory ("$BASEDIR") which will hold the chroots and the git project directory.'
  echo "(don't worry, there's a .gitignore for the chroots)"
  echo "e.g. export BASEDIR=\"/opt/dev/work/client-diag-disc/\""
  echo 'Dying.'
  exit 1
 fi
 
 if [ ! -d "${BASEDIR}" ];
 then
  echo "You need to make sure ${BASEDIR} is a valid, existing directory. This script does not automatically create it as a sanity measure."
  echo 'Dying.'
  exit 1
 fi
 
 if [[ "${EUID}" != "0" ]];
 then
  echo "This script must be run as root."
  echo 'Dying.'
  exit 1
 fi
 
 if [ -f ${LOCKFILE} ];
 then
   echo "Script already running, stale lockfile present, or an error occurred during last run."
   echo "Please clear ${LOCKFILE} by hand before attempting another build."
   echo -n "Timestamp of lockfile is: "
   ls -l ${LOCKFILE} | awk '{print $6" "$7" "$8}'
   exit 1
 else
   touch ${LOCKFILE}
 fi
 
 if [ -f "/usr/bin/systemd-nspawn" ];
  then
    CHROOTCMD="systemd-nspawn -D"
  else
    CHROOTCMD="${CHROOTDIR64}/bin/arch-chroot"
 fi

 cd "${BASEDIR}"
 
 ## Set some vars.
 #MIRROR='http://mirrors.kernel.org/archlinux'
 MIRROR='http://mirror.us.leaseweb.net/archlinux'
 RLSDIR="${MIRROR}/iso/latest"
 
 CURRLS64=$(curl -s ${RLSDIR}/sha1sums.txt | grep bootstrap | awk '{print $2}' | grep 'x86_64')
 CKSUM64=$(curl -s ${RLSDIR}/sha1sums.txt | grep bootstrap | grep x86_64 | awk '{print $1}')
 CURRLS32=$(curl -s ${RLSDIR}/sha1sums.txt | grep bootstrap | awk '{print $2}' | grep 'i686')
 CKSUM32=$(curl -s ${RLSDIR}/sha1sums.txt | grep bootstrap | grep i686 | awk '{print $1}')
 
 ## Fetch latest tarball release
 echo "Checking/fetching snapshots..."
 if [ -f "latest.64.tar.gz" ];
 then
  LOCSUM64=$(sha1sum latest.64.tar.gz | awk '{print $1}')
  if [[ "${CKSUM64}" != "${LOCSUM64}" ]];
  then
    echo "WARNING: CHECKSUMS DON'T MATCH."
    echo "Local: ${LOCSUM64}"
    echo "Remote: ${CKSUM64}"
    echo "Fetching fresh copy."
    curl -o latest.64.tar.gz "${RLSDIR}/${CURRLS64}"
  fi
 else
  curl -o latest.64.tar.gz "${RLSDIR}/${CURRLS64}"
 fi
 
 if [ -f "latest.32.tar.gz" ];
 then
  LOCSUM32=$(sha1sum latest.32.tar.gz | awk '{print $1}')
  if [[ "${CKSUM32}" != "${LOCSUM32}" ]];
  then
    echo "WARNING: CHECKSUMS DON'T MATCH."
    echo "Local: ${LOCSUM32}"
    echo "Remote: ${CKSUM32}"
    echo "Fetching fresh copy."
    curl -o latest.32.tar.gz "${RLSDIR}/${CURRLS32}"
  fi
 else
   curl -o latest.32.tar.gz "${RLSDIR}/${CURRLS32}"
 fi
 
 if [ ! -f "${CHROOTDIR32}/etc/pacman.d/gnupg/trustdb.gpg" ] || [ ! -f "${CHROOTDIR64}/etc/pacman.d/gnupg/trustdb.gpg" ];
 then
   # Now let's ${BASEDIR}/extract that shit
   echo "Extracting snapshots. This will take a while..."
   ## 64-bit
   tar -xpzf latest.64.tar.gz
   ## 32-bit
   tar -xpzf latest.32.tar.gz
   
   # And configure the package manager
   echo "Configuring snapshots..."
   touch ${LOCKFILE}
   sleep 2
   find ${BASEDIR}/extra/pre-build.d/ -exec touch '{}' \;
   rsync -a --exclude '/32' --exclude '/64' ${BASEDIR}/extra/pre-build.d/. ${BASEDIR}/root.x86_64/.
   rsync -a --exclude '/32' --exclude '/64' ${BASEDIR}/extra/pre-build.d/. ${BASEDIR}/root.i686/.
   rsync -a ${BASEDIR}/extra/pre-build.d/64/. ${BASEDIR}/root.x86_64/.
   rsync -a ${BASEDIR}/extra/pre-build.d/32/. ${BASEDIR}/root.i686/.
   chmod -f 755 ${BASEDIR}/extra/pre-build.d/{32/,64/,}etc/customizepkg.d/*
   find ${BASEDIR}/root.x86_64/ -newer ${LOCKFILE} -exec chown -R root:root '{}' \;
   find ${BASEDIR}/root.i686/ -newer ${LOCKFILE} -exec chown -R root:root '{}' \;
   for i in i686 x86_64;
   do
     cat > ${BASEDIR}/root.${i}/etc/os-release << EOF
NAME="Arch Linux"
ID=arch
PRETTY_NAME="Arch Linux"
ANSI_COLOR="0;36"
HOME_URL="https://www.archlinux.org/"
SUPPORT_URL="https://bbs.archlinux.org/"
BUG_REPORT_URL="https://bugs.archlinux.org/"
EOF
     cp ${BASEDIR}/VERSION_INFO.txt ${BASEDIR}/root.${i}/.
   done   

   # And make it usable.
   echo "Initializing chroots..."
   
   for i in ${CHROOTDIR32} ${CHROOTDIR64};
   do
    # Disable NetworkManager. Fuck that shit.
    ln -s /dev/null ${i}/etc/systemd/system/NetworkManager.service
    ln -s /dev/null ${i}/etc/systemd/system/NetworkManager-dispatcher.service
    # Remove the machine-id file so it's automatically generated.
    # NOTE: this kind of fucks things up presently.
    #rm -f ${i}/etc/machine-id
    # Prep pacman
    echo "Prepping ${i}. This will take a while..."
    echo -n "...Key initializing..."
    ${CHROOTCMD} ${i}/ pacman-key --init >> "${LOGFILE}.${FUNCNAME}" 2>&1
    echo "Done."
    echo -n "...Importing keys..."
    ${CHROOTCMD} ${i}/ pacman-key --populate archlinux >> "${LOGFILE}.${FUNCNAME}" 2>&1
    echo "Done."
    # Prep base building system
    echo -n "...Installing base packages..."
    #${CHROOTCMD} ${i}/ pacstrap -dGcM  base 
    # if that doesn't work,
    ${CHROOTCMD} ${i}/ pacman -Syy >> "${LOGFILE}.${FUNCNAME}" 2>&1
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    ${CHROOTCMD} ${i}/ pacman -S --noconfirm --needed base syslinux wget rsync unzip jshon sed sudo abs xmlto bc docbook-xsl git >> "${LOGFILE}.${FUNCNAME}" 2>&1
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    echo "Done."
    echo -n "...Upgrading any outdated packages..."
    ${CHROOTCMD} ${i}/ pacman -Syyu --noconfirm >> "${LOGFILE}.${FUNCNAME}" 2>&1
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    echo "Done. Finishing/cleaning up..."
    ${CHROOTCMD} ${i}/ pacman -S --noconfirm --needed base-devel >> "${LOGFILE}.${FUNCNAME}" 2>&1
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    # Yaourt is busted because Arch Pacman devs are fucking neasighted closed-minded jackasses.
    # If they ever fix their crap, checkout extra/pre-build.d/etc/yaourtrc from git (commit 583a5df84af415990b8c49d7e4ac11dd7b23e0e0)
    ## https://github.com/archlinuxfr/yaourt/issues/67
    ## https://projects.archlinux.org/pacman.git/tree/NEWS#n54
    ## https://bugs.archlinux.org/task/43302
    #${CHROOTCMD} ${i}/ pacman -S --noconfirm --needed yaourt >> "${LOGFILE}.${FUNCNAME}" 2>&1
    mkdir -p ${i}/var/tmp/pkg
    cp ${BASEDIR}/extra/bootstrap/apacman* ${i}/var/tmp/pkg/apacman.tar.xz
    #${CHROOTCMD} ${i} "pacman --noconfirm -U /var/tmp/pkg/apacman.tar.xz" >> "${LOGFILE}.${FUNCNAME}" 2>&1
    ${CHROOTCMD} ${i} bash -c "pacman --noconfirm -U /var/tmp/pkg/apacman.tar.xz && mkdir /var/tmp/apacman && chmod 0750 /var/tmp/apacman && chown root:aurbuild /var/tmp/apacman " >> "${LOGFILE}.${FUNCNAME}" 2>&1
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    ${CHROOTCMD} ${i} bash -c "apacman -S --noconfirm --noedit --skipinteg -S apacman-deps expac" >> "${LOGFILE}.${FUNCNAME}" 2>&1
    #rm -rf ${i}/var/tmp/pkg
    #${CHROOTCMD} ${i}/ pacman -S --noconfirm --needed yaourt >> "${LOGFILE}.${FUNCNAME}" 2>&1
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
   done
   ${CHROOTCMD} ${CHROOTDIR64}/ 'pacman --noconfirm -R gcc-libs libtool' >> "${LOGFILE}.${FUNCNAME}" 2>&1
   ${CHROOTCMD} ${CHROOTDIR64}/ 'pacman --noconfirm -S multilib-devel' >> "${LOGFILE}.${FUNCNAME}" 2>&1
 fi

 # And let's do some more optimization.
 if [[ "${I_AM_A_RACECAR}" == "y" ]];
 then
  CPUCNT=$(grep processor /proc/cpuinfo | wc -l)
  ((CPUCNT++))
  sed -i -e "/^[[:space:]]*#*MAKEFLAGS=.*$/aMAKEFLAGS=\"-j${CPUCNT}\"" ${CHROOTDIR64}/etc/makepkg.conf
  sed -i -e "/^[[:space:]]*#*MAKEFLAGS=.*$/aMAKEFLAGS=\"-j${CPUCNT}\"" ${CHROOTDIR32}/etc/makepkg.conf
 fi
 
 # Baseline packages
 echo "Installing baseline packages..."
 PKGLIST=$(sed -e '/^[[:space:]]*#/d ; /^[[:space:]]*$/d' ${BASEDIR}/lib/prereqs/iso.pkgs.lst | tr '\n' ' ')
 for i in ${CHROOTDIR32} ${CHROOTDIR64};
 do
  set +e
  for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
  set -e
  ${CHROOTCMD} ${i}/ bash -c "yes '' | apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}" >> "${LOGFILE}.${FUNCNAME}" 2>&1
  set +e
  for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
  set -e
 done
 # 32-bit
 PKGLIST=$(sed -e '/^[[:space:]]*#/d ; /^[[:space:]]*$/d' ${BASEDIR}/lib/prereqs/iso.pkgs.lst.32 | tr '\n' ' ')
 if [ -n "${PKGLIST}" ];
 then
   ${CHROOTCMD} ${CHROOTDIR32}/ /usr/bin/bash -c "apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}" >> "${LOGFILE}.${FUNCNAME}" 2>&1
 fi
 set +e
 for x in $(find ${CHROOTDIR32}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%.pacorig} ; done
 set -e
 # 64-bit
 PKGLIST=$(sed -e '/^[[:space:]]*#/d ; /^[[:space:]]*$/d' ${BASEDIR}/lib/prereqs/iso.pkgs.lst.64 | tr '\n' ' ')
 if [ -n "${PKGLIST}" ];
 then
   ${CHROOTCMD} ${CHROOTDIR64}/ /usr/bin/bash -c "apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}" >> "${LOGFILE}.${FUNCNAME}" 2>&1
 fi
 set +e
 for x in $(find ${CHROOTDIR64}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%.pacorig} ; done
 set -e

 # extra packages
 sed -i -e '/base-devel/d ; /multilib-devel/d' ${BASEDIR}/extra/packages.{both,64}
 # both
 echo "Installing extra common packages..."
 PKGLIST=$(sed -e '/^[[:space:]]*#/d ; /^[[:space:]]*$/d' ${BASEDIR}/extra/packages.both | tr '\n' ' ')
 for i in ${CHROOTDIR32} ${CHROOTDIR64};
 do
    echo "Running post-build tasks in ${i}..."
    ${CHROOTCMD} ${i}/ "/root/post-build.sh" >> "${LOGFILE}.${FUNCNAME}" 2>&1
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    set +e
    ${CHROOTCMD} ${i}/ /usr/bin/bash -c "apacman --noconfirm --noedit --skipinteg -S --needed linux" >> "${LOGFILE}.${FUNCNAME}" 2>&1
    cp -a ${i}/boot/vmlinuz-linux ${i}/boot/vmlinuz-linux-${DISTNAME}
    cp -a ${i}/boot/initramfs-linux.img ${i}/boot/initramfs-linux-${DISTNAME}.img
    set -e
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    # Uncomment if you wish to use the mkpasswd binary from within the chroot...
    #${CHROOTCMD} ${i}/ bash -c "apacman --noconfirm --noedit --skipinteg -S --needed debian-whois-mkpasswd" >> "${LOGFILE}.${FUNCNAME}" 2>&1
    #for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    echo -n "Regular packages..."
    ${CHROOTCMD} ${i}/ bash -c "yes '' | apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}" >> "${LOGFILE}.${FUNCNAME}" 2>&1
    set +e
    for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%%.pacorig} ; done
    set -e
    # User creation
    echo -n "...Creating ${REGUSR} user..."
    ${CHROOTCMD} ${i}/ useradd -m -s /bin/bash -c "Default user" ${REGUSR} >> "${LOGFILE}.${FUNCNAME}" 2>&1
    ${CHROOTCMD} ${i}/ usermod -aG users,games,video,audio ${REGUSR} >> "${LOGFILE}.${FUNCNAME}" 2>&1
    ${CHROOTCMD} ${i}/ passwd -d ${REGUSR} >> "${LOGFILE}.${FUNCNAME}" 2>&1
    mkdir -p ${i}/etc/sudoers.d ; chmod 750 ${i}/etc/sudoers.d
    printf "Defaults:${REGUSR} \041lecture\n${REGUSR} ALL=(ALL) ALL\n" >> ${i}/etc/sudoers.d/${REGUSR}
    if [[ -n "${REGUSR_PASS}" && "${REGUSR_PASS}" != '{[BLANK]}' ]];
    then
      #${CHROOTCMD} ${i}/ "/usr/bin/echo ${REGUSR}:${REGUSR_PASS} | chpasswd -e" >> "${LOGFILE}.${FUNCNAME}" 2>&1
      sed -i -e "s|^${REGUSR}::|${REGUSR}:${REGUSR_PASS}:|g" ${i}/etc/shadow
    elif [[ "${REGUSR_PASS}" == '{[BLANK]}' ]];
    then
      ${CHROOTCMD} ${i}/ passwd -d ${REGUSR} >> "${LOGFILE}.${FUNCNAME}" 2>&1
    else
      ${CHROOTCMD} ${i}/ usermod -L ${REGUSR} >> "${LOGFILE}.${FUNCNAME}" 2>&1
    fi
    if [[ -n "${ROOT_PASS}" && "${ROOT_PASS}" != '{[BLANK]}' ]];
    then
      #${CHROOTCMD} ${i}/ "/usr/bin/echo root:${ROOT_PASS} | chpasswd -e" >> "${LOGFILE}.${FUNCNAME}" 2>&1
      sed -i -e "s|^root::|root:${ROOT_PASS}:|g" ${i}/etc/shadow
    elif [[ "${ROOT_PASS}" == '{[BLANK]}' ]];
    then
      ${CHROOTCMD} ${i}/ passwd -d root >> "${LOGFILE}.${FUNCNAME}" 2>&1
    else
      ${CHROOTCMD} ${i}/ usermod -L root >> "${LOGFILE}.${FUNCNAME}" 2>&1
    fi
    # The following is supposed to do the same as the above, but "cleaner". However, it currently fails with "execv() failed: No such file or directory"
    ##${CHROOTCMD} ${i}/ usermod -L root >> "${LOGFILE}.${FUNCNAME}" 2>&1
    echo "Done."
 done
 
 for i in ${CHROOTDIR32} ${CHROOTDIR64};
 do
  set +e
  for x in $(find ${i}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%.pacorig} ; done
  ${CHROOTCMD} ${i}/ /usr/bin/bash -c "mkinitcpio -p linux" >> "${LOGFILE}.${FUNCNAME}" 2>&1
  cp -a ${i}/boot/initramfs-linux.img ${i}/boot/initramfs-linux-${DISTNAME}.img
  set -e
 done
 
 # 32-bit
 echo "Installing extra packages for 32-bit..."
 PKGLIST=$(sed -e '/^[[:space:]]*#/d ; /^[[:space:]]*$/d' ${BASEDIR}/extra/packages.32 | tr '\n' ' ')
 if [ -n "${PKGLIST}" ];
 then
   ${CHROOTCMD} ${CHROOTDIR32}/ /usr/bin/bash -c "apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}" >> "${LOGFILE}.${FUNCNAME}" 2>&1
 fi
 set +e
 for x in $(find ${CHROOTDIR32}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%.pacorig} ; done
 set -e
 echo "Done."
 
 # 64-bit
 echo "Installing estra packages for 64-bit..."
 PKGLIST=$(sed -e '/^[[:space:]]*#/d ; /^[[:space:]]*$/d' ${BASEDIR}/extra/packages.64 | tr '\n' ' ')
 if [ -n "${PKGLIST}" ];
 then
   ${CHROOTCMD} ${CHROOTDIR64}/ /usr/bin/bash -c "apacman --noconfirm --noedit --skipinteg -S --needed ${PKGLIST}" >> "${LOGFILE}.${FUNCNAME}" 2>&1
 fi
 set +e
 for x in $(find ${CHROOTDIR64}/etc/ -type f -iname "*.pacorig");do mv -f ${x} ${x%.pacorig} ; done
 set -e
 echo "Done."

 echo "Syncing overlay..."
 touch ${LOCKFILE}
 sleep 2
 find ${BASEDIR}/overlay -exec touch '{}' \;
 rsync -a --exclude '/32' --exclude '/64' ${BASEDIR}/overlay/. ${CHROOTDIR64}/.
 rsync -a --exclude '/32' --exclude '/64' ${BASEDIR}/overlay/. ${CHROOTDIR32}/.
 rsync -a ${BASEDIR}/overlay/32/. ${CHROOTDIR32}/.
 rsync -a ${BASEDIR}/overlay/64/. ${CHROOTDIR64}/.
 find ${CHROOTDIR64}/ -newer ${LOCKFILE} -exec chown -R root:root '{}' \;
 find ${CHROOTDIR32}/ -newer ${LOCKFILE} -exec chown -R root:root '{}' \;
 chown -R 1000:1000 ${CHROOTDIR32}/home/${REGUSR}
 chown -R 1000:1000 ${CHROOTDIR64}/home/${REGUSR}
 find ${CHROOTDIR64}/home/${REGUSR}/ -type d -exec chmod 700 '{}' \;
 find ${CHROOTDIR64}/home/${REGUSR}/ -type f -exec chmod 600 '{}' \;
 find ${CHROOTDIR32}/home/${REGUSR}/ -type d -exec chmod 700 '{}' \;
 find ${CHROOTDIR32}/home/${REGUSR}/ -type f -exec chmod 600 '{}' \;
 find ${CHROOTDIR64}/root/ -type d -exec chmod 700 '{}' \;
 find ${CHROOTDIR64}/root/ -type f -exec chmod 600 '{}' \;
 find ${CHROOTDIR32}/root/ -type d -exec chmod 700 '{}' \;
 find ${CHROOTDIR32}/root/ -type f -exec chmod 600 '{}' \;
 chmod 600 ${CHROOTDIR64}/etc/ssh/*
 chmod 600 ${CHROOTDIR32}/etc/ssh/*
 echo "Done."

 
 #rm -f ${LOCKFILE}
 
 echo "Chroot setup complete."

}

if [[ ! -f "${BASEDIR}/root.x86_64/VERSION_INFO.txt" && ! -f "${BASEDIR}/root.x86_64/VERSION_INFO.txt" ]];
then
  mkchroot
fi

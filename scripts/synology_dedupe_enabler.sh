#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Enables data deduplication with non-Synology drives and unsupported NAS models
#
# Github: https://github.com/wanlinwang/HDD-Dedupe-Enabler-for-Synology
# Forked from: https://github.com/007revad/Synology_enable_Deduplication
# Script verified at https://www.shellcheck.net/
#
# To run in a shell (replace /volume1/scripts/ with path to script):
# sudo /volume1/scripts/synology_dedupe_enabler.sh
#-------------------------------------------------------------------------------

# Added support for DSM 7.0.1 to 7.2 (untested)

scriptver="v1.5.1"  # 更新版本号
script=HDD_Dedupe_Enabler  # 新名称
repo="wanlinwang/HDD-Dedupe-Enabler-for-Synology"  # 您的仓库
scriptname=synology_dedupe_enabler  # 新文件名

# Generate timestamp for backup files (YYYYMMDD_HHMMSS)
backup_timestamp=$(date +"%Y%m%d_%H%M%S")

# Prevent Entware or user edited PATH causing issues (robust removal)
# shellcheck disable=SC2155  # Declare and assign separately to avoid masking return values
export PATH="$(printf '%s' "$PATH" \
  | sed -e 's#:/opt/bin##g' -e 's#:/opt/sbin##g' \
        -e 's#^/opt/bin:##' -e 's#^/opt/sbin:##')"

# Force C locale for consistent tool output
export LC_ALL=C

SYNOBIN="/usr/syno/bin"

# Check BASH variable is bash
if [ ! "$(basename "$BASH")" = bash ]; then
    echo "This is a bash script. Do not run it with $(basename "$BASH")"
    printf \\a
    exit 1
fi

# Check script is running on a Synology NAS
if ! /usr/bin/uname -a | grep -i synology >/dev/null; then
    echo "This script is NOT running on a Synology NAS!"
    echo "Copy the script to a folder on the Synology"
    echo "and run it from there."
    exit 1
fi

ding(){ printf \\a; }

list_backups(){
    # List all timestamped backup files
    local cyan_color='\e[0;36m'
    local off_color='\e[0m'
    echo -e "\n${cyan_color}Existing backup files:${off_color}"
    local found=0
    if ls /usr/lib/libhwcontrol.so.1.bak.* 2>/dev/null | head -5; then found=1; fi
    if ls /etc.defaults/synoinfo.conf.bak.* 2>/dev/null | head -5; then found=1; fi
    if [[ -f "$strgmgr" ]]; then
        if ls "${strgmgr}".bak.* 2>/dev/null | head -5; then found=1; fi
    fi
    if [[ $found -eq 0 ]]; then echo "  No backup files found."; fi
    echo ""
}

usage(){ 
    cat <<EOF
$script $scriptver

Usage: $(basename "$0") [options]

Options:
  -c, --check           Check value in file and backup file
  -r, --restore         Undo all changes made by the script
  -t, --tiny            Enable tiny data deduplication (only needs 4GB RAM)
                          DSM 7.2.1 and later only
      --hdd             Enable data deduplication for HDDs.
                          Can cause files to become more fragmented,
                          resulting in decreased access performance.
  -e, --email           Disable colored text in output for scheduler emails
      --autoupdate=AGE  Auto update script (useful when script is scheduled)
                          AGE is how many days old a release must be before
                          auto-updating. AGE must be a number: 0 or greater
  -s, --skip            Skip memory amount check (for testing)
      --list-backups    List all timestamped backup files
      --dry-run         Preview changes without making any modifications
  -h, --help            Show this help message
  -v, --version         Show the script version

Note: All file modifications are backed up with timestamp (YYYYMMDD_HHMMSS)

EOF
    exit 0
}

scriptversion(){ 
    cat <<EOF
$script $scriptver

See https://github.com/$repo
EOF
    exit 0
}

# Save options used
args=("$@")
autoupdate=""

# Check for flags with getopt
if options="$(getopt -o abcdefghijklmnopqrstuvwxyz0123456789 -l \
    skip,check,restore,help,version,tiny,hdd,email,autoupdate:,log,debug,list-backups,dry-run -- "$@")"; then
    eval set -- "$options"
    while true; do
        case "${1,,}" in
            -h|--help) usage ;;
            -v|--version) scriptversion ;;
            -t|--tiny) tiny=yes ;;
            --hdd) hdd=yes ;;
            -s|--skip) skip=yes ;;
            -l|--log) : ;;  # reserved
            --dry-run) dryrun=yes ;;
            --list-backups)
                if /usr/bin/uname -a 2>/dev/null | grep -i synology >/dev/null; then
                    buildnumber=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/VERSION buildnumber 2>/dev/null)
                    if [[ $buildnumber -gt 64570 ]]; then
                        strgmgr="/usr/local/packages/@appstore/StorageManager/ui/storage_panel.js"
                    else
                        strgmgr="/usr/syno/synoman/webman/modules/StorageManager/storage_panel.js"
                    fi
                fi
                list_backups
                exit 0
                ;;
            -d|--debug) debug=yes ;;
            -c|--check) check=yes; break ;;
            -r|--restore) restore=yes; break ;;
            -e|--email) color=no ;;
            --autoupdate)
                autoupdate=yes
                if [[ $2 =~ ^[0-9]+$ ]]; then delay="$2"; shift; else delay="0"; fi
                ;;
            --) shift; break ;;
            *) echo -e "Invalid option '$1'\n"; usage "$1" ;;
        esac
        shift
    done
else
    echo
    usage
fi

if [[ $debug == "yes" ]]; then
    set -x
    export PS4='`[[ $? == 0 ]] || echo "\e[1;31;40m($?)\e[m\n "`:.$LINENO:'
fi

# Shell Colors
if [[ $color != "no" ]]; then
    Red='\e[0;31m'; Yellow='\e[0;33m'; Cyan='\e[0;36m'; Error='\e[41m'; Off='\e[0m'
else
    echo ""  # For task scheduler email readability
    Red=''; Yellow=''; Cyan=''; Error=''; Off=''
fi

# Check script is running as root (skip check in dry-run mode)
if [[ ${EUID:-$(id -u)} -ne 0 ]] && [[ $dryrun != "yes" ]]; then
    ding
    echo -e "${Error}ERROR${Off} This script must be run as sudo or root!"
    exit 1
fi

# Get DSM versions
major=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/VERSION majorversion)
minor=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/VERSION minorversion)
micro=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/VERSION micro)

# Get NAS model
model=$(cat /proc/sys/kernel/syno_hw_version)

# Show script version
echo "$script $scriptver"

# Get DSM full version
productversion=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/VERSION productversion)
buildphase=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/VERSION buildphase)
buildnumber=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/VERSION buildnumber)
smallfixnumber=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/VERSION smallfixnumber)
smallfixnumber=${smallfixnumber:-0}
if [[ $buildphase == GM ]]; then buildphase=""; fi
if [[ $smallfixnumber -gt 0 ]]; then smallfix="-$smallfixnumber"; fi
echo -e "$model DSM $productversion-$buildnumber$smallfix $buildphase\n"

# Get StorageManager version
storagemgrver=$("$SYNOBIN/synopkg" version StorageManager 2>/dev/null)
if [[ $storagemgrver ]]; then echo -e "StorageManager $storagemgrver \n"; fi

# Show options used
if [[ ${#args[@]} -gt 0 ]]; then
    echo -e "Using options: ${args[*]}"
fi

# Show dry-run mode notification
if [[ $dryrun == "yes" ]]; then
    echo -e "\n${Cyan}=== DRY RUN MODE ===${Off}"
    echo -e "${Cyan}No changes will be made. Previewing actions only.${Off}\n"
fi

if [[ $major$minor$micro -lt "701" ]]; then
    ding
    echo "Btrfs Data Deduplication only works in DSM 7.0.1 and later."
    exit 1
fi

# Check model (and DSM version for that model) supports dedupe
if [[ ! -f /usr/syno/sbin/synobtrfsdedupe ]]; then
    arch=$("$SYNOBIN/synogetkeyvalue" /etc.defaults/synoinfo.conf platform_name)
    echo "Models with $arch CPUs do not support Btrfs Data Deduplication."
    echo "Only models with V1000, R1000, Geminilake, Broadwellnkv2,"
    echo "Broadwellnk, Broadwell, Purley and Epyc7002 CPUs are supported."
    exit
fi

#------------------------------------------------------------------------------
# Check latest release with GitHub API (robust fallbacks)

syslog_set(){ 
    if [[ ${1,,} == "info" || ${1,,} == "warn" || ${1,,} == "err" ]]; then
        if [[ $autoupdate == "yes" ]]; then
            # Add entry to Synology system log
            /usr/syno/bin/synologset1 sys "$1" 0x11100000 "$2"
        fi
    fi
}

release=""
if command -v curl >/dev/null; then
    release=$(curl --silent -m 10 --connect-timeout 5 \
        "https://api.github.com/repos/$repo/releases/latest" || echo "")
fi

tag=""; shorttag=""
if [[ -n $release ]]; then
    tag=$(echo "$release" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    shorttag="${tag#v}"
fi

# Compute "newer" flag using robust comparison
newer=no
if [[ -n $tag && -n $scriptver ]]; then
    if command -v sort >/dev/null && sort -V </dev/null &>/dev/null; then
        # If sorted order check fails => tag is newer than scriptver
        if ! printf "%s\n%s\n" "$tag" "$scriptver" | sort -V --check=quiet 2>/dev/null; then
            newer=yes
        fi
    else
        # Fallback: naive string compare without 'v'
        _t="${tag#v}"; _s="${scriptver#v}"
        [[ "$_t" != "$_s" && "$_t" > "$_s" ]] && newer=yes
    fi
fi

# Days since release (optional; skip if date -d not available)
age=""
if [[ -n $release ]]; then
    published=$(echo "$release" | grep '"published_at":' | sed -E 's/.*"([^"]+)".*/\1/')
    if command -v date >/dev/null && date -d 1970-01-01 +%s &>/dev/null; then
        published_epoch=$(date -d "${published:0:10}" +%s 2>/dev/null || echo "")
        now_epoch=$(date +%s)
        if [[ -n $published_epoch ]]; then
            age=$(((now_epoch - published_epoch)/(60*60*24)))
        fi
    fi
fi

# Get script location
source=${BASH_SOURCE[0]}
while [ -L "$source" ]; do
    scriptpath=$( cd -P "$( dirname "$source" )" >/dev/null 2>&1 && pwd )
    source=$(readlink "$source")
    [[ $source != /* ]] && source=$scriptpath/$source
done
scriptpath=$( cd -P "$( dirname "$source" )" >/dev/null 2>&1 && pwd )
scriptfile=$( basename -- "$source" )
echo "Running from: ${scriptpath}/$scriptfile"

# Warn if script located on M.2 drive (best-effort; skip if lvm tools missing)
scriptvol=$(echo "$scriptpath" | cut -d"/" -f2)
if command -v lvdisplay >/dev/null && command -v pvdisplay >/dev/null; then
    vg=$(lvdisplay 2>/dev/null | grep /volume_"${scriptvol#volume}" | cut -d"/" -f3 | head -n1)
    md=$(pvdisplay 2>/dev/null | grep -B 1 -E '[ ]'"$vg" | grep /dev/ | cut -d"/" -f3 | head -n1)
    if [[ -n $md ]] && cat /proc/mdstat 2>/dev/null | grep "$md" | grep -qi nvme; then
        echo -e "${Yellow}WARNING${Off} Don't store this script on an NVMe volume!"
    fi
fi

cleanup_tmp(){ 
    cleanup_err=
    if [[ -f "/tmp/$script-$shorttag.tar.gz" ]]; then
        rm -f "/tmp/$script-$shorttag.tar.gz" || cleanup_err=1
    fi
    if [[ -d "/tmp/$script-$shorttag" ]]; then
        rm -rf "/tmp/$script-$shorttag" || cleanup_err=1
    fi
    if [[ $cleanup_err ]]; then
        syslog_set warn "$script update failed to delete tmp files"
    fi
}

if [[ $newer == yes ]]; then
    echo -e "\n${Cyan}There is a newer version of this script available.${Off}"
    echo -e "Current version: ${scriptver}\nLatest version:  $tag"
    scriptdl="$scriptpath/$script-$shorttag"
    if [[ -f ${scriptdl}.tar.gz ]] || [[ -f ${scriptdl}.zip ]]; then
        echo "You have the latest version downloaded but are using an older version"
        sleep 3
    elif [[ -d $scriptdl ]]; then
        echo "You have the latest version extracted but are using an older version"
        sleep 3
    else
        if [[ $autoupdate == "yes" ]]; then
            # Only auto-update if we could compute 'age'
            if [[ -n $age && $age -ge ${delay:-0} ]]; then
                echo "Downloading $tag"
                reply=y
            else
                echo "Skipping auto-update (age unknown or < delay)."
            fi
        else
            echo -e "${Cyan}Do you want to download $tag now?${Off} [y/n]"
            read -r -t 30 reply || reply=n
        fi

        if [[ ${reply,,} == "y" ]]; then
            cleanup_tmp
            if cd /tmp; then
                url="https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
                if ! curl -JLO -m 30 --connect-timeout 5 "$url"; then
                    echo -e "${Error}ERROR${Off} Failed to download $script-$shorttag.tar.gz!"
                    syslog_set warn "$script $tag failed to download"
                else
                    if [[ -f /tmp/$script-$shorttag.tar.gz ]]; then
                        if ! tar -xf "/tmp/$script-$shorttag.tar.gz" -C "/tmp"; then
                            echo -e "${Error}ERROR${Off} Failed to extract $script-$shorttag.tar.gz!"
                            syslog_set warn "$script failed to extract $script-$shorttag.tar.gz!"
                        else
                            chmod a+x "/tmp/$script-$shorttag/"*.sh 2>/dev/null || permerr=1
                            if ! cp -p "/tmp/$script-$shorttag/${scriptname}.sh" "${scriptpath}/${scriptfile}"; then
                                copyerr=1
                                echo -e "${Error}ERROR${Off} Failed to copy script to:\n $scriptpath/${scriptfile}"
                                syslog_set warn "$script failed to copy $tag to script location"
                            fi
                            if [[ $scriptpath =~ /volume* ]]; then
                                chmod 664 "/tmp/$script-$shorttag/CHANGELOG.md" 2>/dev/null || permerr=1
                                cp -p "/tmp/$script-$shorttag/CHANGELOG.md" \
                                  "${scriptpath}/${scriptname}_CHANGELOG.md" 2>/dev/null || {
                                    [[ $autoupdate != "yes" ]] && copyerr=1
                                  }
                            fi
                            cleanup_tmp
                            if [[ $copyerr != 1 && $permerr != 1 ]]; then
                                echo -e "\n$tag ${scriptfile} downloaded to: ${scriptpath}\n"
                                syslog_set info "$script successfully updated to $tag"
                                printf -- '-%.0s' {1..79}; echo
                                exec "${scriptpath}/$scriptfile" "${args[@]}"
                            else
                                syslog_set warn "$script update to $tag had errors"
                            fi
                        fi
                    else
                        echo -e "${Error}ERROR${Off} /tmp/$script-$shorttag.tar.gz not found!"
                        syslog_set warn "/tmp/$script-$shorttag.tar.gz not found"
                    fi
                fi
                cd "$scriptpath" || echo -e "${Error}ERROR${Off} Failed to cd to script location!"
            else
                echo -e "${Error}ERROR${Off} Failed to cd to /tmp!"
                syslog_set warn "$script update failed to cd to /tmp"
            fi
        fi
    fi
fi

#------------------------------------------------------------------------------
# Set file variables

synoinfo="/etc.defaults/synoinfo.conf"
synoinfo2="/etc/synoinfo.conf"
libhw="/usr/lib/libhwcontrol.so.1"

if [[ $buildnumber -gt 64570 ]]; then
    # DSM 7.2.1 and later
    strgmgr="/usr/local/packages/@appstore/StorageManager/ui/storage_panel.js"
else
    # DSM 7.0.1 to 7.2
    strgmgr="/usr/syno/synoman/webman/modules/StorageManager/storage_panel.js"
fi

if [[ ! -f ${libhw} ]]; then
    ding
    echo -e "${Error}ERROR${Off} $(basename -- "$libhw") not found!"
    exit 1
fi

rebootmsg(){ 
    echo -e "\n${Cyan}The Synology needs to restart.${Off}"
    echo -e "Type ${Cyan}yes${Off} to reboot now."
    echo -e "Type anything else to quit (if you will restart it yourself)."
    read -r -t 10 answer || answer=""
    if [[ ${answer,,} != "yes" ]]; then exit; fi
    sync || true
    if [[ -x /usr/syno/sbin/synopoweroff ]]; then
        /usr/syno/sbin/synopoweroff -r || reboot
    else
        reboot
    fi
}

reloadmsg(){ 
    echo -e "\nFinished"
    echo -e "\nIf you have DSM open in a browser you need to"
    echo "refresh the browser window or tab."
    echo "You may also need to reboot."
    exit
}

#----------------------------------------------------------
# Restore changes from backup file

compare_md5(){ 
    # $1 is file 1 ; $2 is file 2
    if [[ -f "$1" && -f "$2" ]]; then
        if [[ $(md5sum -b "$1" | awk '{print $1}') == $(md5sum -b "$2" | awk '{print $1}') ]]; then
            return 0
        else
            return 1
        fi
    else
        restoreerr=$((restoreerr+1))
        return 2
    fi
}

if [[ $restore == "yes" ]]; then
    echo ""
    if [[ -f ${synoinfo}.bak ]] || [[ -f ${libhw}.bak ]] || [[ -f ${strgmgr}.${storagemgrver} ]]; then

        # Restore synoinfo.conf from backup
        if [[ -f ${synoinfo}.bak ]]; then
            keyvalues=("support_btrfs_dedupe" "support_tiny_btrfs_dedupe")
            for v in "${!keyvalues[@]}"; do
                defaultval="$("$SYNOBIN/synogetkeyvalue" ${synoinfo}.bak "${keyvalues[v]}")"
                if [[ -z $defaultval ]]; then defaultval="no"; fi
                currentval="$("$SYNOBIN/synogetkeyvalue" ${synoinfo} "${keyvalues[v]}")"
                if [[ $currentval != "$defaultval" ]]; then
                    if "$SYNOBIN/synosetkeyvalue" "$synoinfo" "${keyvalues[v]}" "$defaultval"; then
                        restored="yes"
                        echo "Restored ${keyvalues[v]} = $defaultval"
                    fi
                fi
                "$SYNOBIN/synosetkeyvalue" "$synoinfo2" "${keyvalues[v]}" "$defaultval"
            done
        fi

        # Restore storage_panel.js from backup (string-based)
        if [[ -f "${strgmgr}.$storagemgrver" ]]; then
            string1="(SYNO.SDS.StorageUtils.supportBtrfsDedupe,)"
            string2="(SYNO.SDS.StorageUtils.supportBtrfsDedupe&&e.dedup_info.show_config_btn)"
            if grep -Fq "$string1" "${strgmgr}"; then
                # Restore string in file
                sed -i "s/${string1}/${string2/&&/\\&\\&}/g" "$strgmgr"
                # Check we restored string in file (FIX: use variable content)
                if grep -Fq "$string2" "${strgmgr}"; then
                    restored="yes"
                    echo "Restored $(basename -- "$strgmgr")"
                else
                    restoreerr=1
                    echo -e "${Error}ERROR${Off} Failed to restore $(basename -- "$strgmgr")!"
                fi
            fi
        else
            echo "No backup of $(basename -- "$strgmgr") found."
        fi

        if [[ -f "${libhw}.bak" ]]; then
            filesize=$(wc -c "${libhw}" | awk '{print $1}')
            filebaksize=$(wc -c "${libhw}.bak" | awk '{print $1}')
            if [[ ! $filesize -eq "$filebaksize" ]]; then
                echo -e "${Yellow}WARNING Backup file size is different to file!${Off}"
                echo "Do you want to restore this backup? [yes/no]:"
                read -r -t 20 answer || answer="no"
                if [[ $answer != "yes" ]]; then
                    exit
                fi
            fi
            if ! compare_md5 "$libhw".bak "$libhw"; then
                if cp -p "$libhw".bak "$libhw" ; then
                    restored="yes"; reboot="yes"
                    echo "Restored $(basename -- "$libhw")"
                else
                    restoreerr=1
                    echo -e "${Error}ERROR${Off} Failed to restore $(basename -- "$libhw")!"
                fi
            fi
        else
            echo "No backup of $(basename -- "$libhw") found."
        fi

        if [[ -z $restoreerr ]]; then
            if [[ $restored == "yes" ]]; then
                echo -e "\nRestore successful."
                reloadmsg
            else
                echo -e "Nothing to restore."
            fi
        fi

        if [[ $reboot == "yes" ]]; then
            rebootmsg
        fi
    else
        echo -e "No backups to restore from."
    fi
    exit
fi

#----------------------------------------------------------
# Check NAS has enough memory

if [[ $restore != "yes" && $skip != "yes" ]]; then
    ramtotal=""

    if command -v dmidecode >/dev/null; then
        # Prefer dmidecode if available
        mapfile -t dmi_lines < <(dmidecode -t memory 2>/dev/null | grep -E "[Ss]ize: [0-9]+ [MG]B$")
        if [[ ${#dmi_lines[@]} -gt 0 ]]; then
            for line in "${dmi_lines[@]}"; do
                set -- $line
                # "Size: <num> <MB|GB>"
                ramsize="$2"; unit="$3"
                if [[ $unit == "GB" ]]; then ramsize=$((ramsize * 1024)); fi
                ramtotal=$(( ${ramtotal:-0} + ramsize ))
            done
        fi
    fi

    # Fallback to /proc/meminfo
    if [[ -z $ramtotal || $ramtotal -eq 0 ]]; then
        ram_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
        if [[ -n $ram_kb ]]; then
            ramtotal=$((ram_kb/1024))  # MB
        fi
    fi

    if [[ -z $ramtotal || $ramtotal -eq 0 ]]; then
        ding
        echo -e "\n${Error}ERROR${Off} Unable to determine the amount of installed memory!"
        exit 1
    fi

    ramgb=$((ramtotal / 1024))
    # DSM 7.2.1+ supports tiny mode explicitly（用 buildnumber 辨识）
    if [[ $buildnumber -gt 64570 ]]; then
        if [[ $tiny == "yes" || $ramtotal -lt 16384 ]]; then
            ramneeded="4096"  # Tiny dedupe only needs 4GB RAM
            tiny="yes"
        else
            ramneeded="16384"
            tiny=""
        fi
    else
        ramneeded="16384"
        tiny=""
    fi

    if [[ $ramtotal -lt "$ramneeded" ]]; then
        ding
        echo -e "\n${Error}ERROR${Off} Not enough memory installed for deduplication: $ramgb GB"
        exit 1
    else
        echo -e "\nNAS has $ramgb GB of memory."
    fi
fi

#----------------------------------------------------------
# Edit libhwcontrol.so.1

findbytes(){ 
    # Get decimal position of matching hex string
    match=$(od -v -t x1 "$1" |
    sed 's/[^ ]* *//' |
    tr '\012' ' ' |
    grep -b -i -o "$hexstring" |
    cut -d ':' -f 1 |
    xargs -I % expr % / 3)

    # Convert decimal position of matching hex string to hex
    array=("$match")
    if [[ ${#array[@]} -gt 1 ]]; then
        num="0"
        while [[ $num -lt "${#array[@]}" ]]; do
            poshex=$(printf "%x" "${array[$num]}")
            [[ $debug == "yes" ]] && echo "${array[$num]} = $poshex"
            seek="${array[$num]}"
            xxd=$(xxd -u -l 12 -s "$seek" "$1")
            [[ $debug == "yes" ]] && printf %s "$xxd" | cut -d" " -f1-7
            bytes=$(printf %s "$xxd" | cut -d" " -f6)
            num=$((num +1))
        done
    elif [[ -n $match ]]; then
        poshex=$(printf "%x" "$match")
        [[ $debug == "yes" ]] && echo "$match = $poshex"
        seek="$match"
        xxd=$(xxd -u -l 12 -s "$seek" "$1")
        [[ $debug == "yes" ]] && printf %s "$xxd" | cut -d" " -f1-7
        bytes=$(printf %s "$xxd" | cut -d" " -f6)
    else
        bytes=""
    fi
}

# --check only
if [[ $check == "yes" ]]; then
    err=0
    sbd=support_btrfs_dedupe
    stbd=support_tiny_btrfs_dedupe
    setting="$("$SYNOBIN/synogetkeyvalue" "$synoinfo" ${sbd})"
    setting2="$("$SYNOBIN/synogetkeyvalue" "$synoinfo" ${stbd})"
    if [[ $setting == "yes" ]]; then
        echo -e "\nBtrfs Data Deduplication is ${Cyan}enabled${Off}."
    else
        echo -e "\nBtrfs Data Deduplication is ${Cyan}not${Off} enabled."
    fi
    if [[ $setting2 == "yes" ]]; then
        echo -e "Tiny Btrfs Data Deduplication is ${Cyan}enabled${Off}."
    else
        echo -e "Tiny Btrfs Data Deduplication is ${Cyan}not${Off} enabled."
    fi

    if [[ -f "$strgmgr" ]]; then
        if ! grep -Fq '&&e.dedup_info.show_config_btn' "$strgmgr"; then
            echo -e "\nDedupe config menu for HDDs and 2.5\" SSDs is ${Cyan}enabled${Off}."
        else
            echo -e "\nDedupe config menu for HDDs and 2.5\" SSDs is ${Cyan}not${Off} enabled."
            echo "Run the script with the --hdd option if you want it enabled."
        fi
    fi

    echo -e "\nChecking non-Synology drive supported."
    hexstring="80 3E 00 B8 01 00 00 00 90 90 48 8B"
    findbytes "$libhw"
    if [[ $bytes == "9090" ]]; then
        echo -e "File is already edited."
    else
        hexstring="80 3E 00 B8 01 00 00 00 75 2. 48 8B"
        findbytes "$libhw"
        if [[ $bytes =~ 752[0-9] ]]; then
            echo -e "File is ${Cyan}not${Off} edited."
        else
            echo -e "${Red}hex string not found!${Off}"
            err=1
        fi
    fi

    if [[ -f ${libhw}.bak ]]; then
        echo -e "\nChecking value in backup file."
        hexstring="80 3E 00 B8 01 00 00 00 75 2. 48 8B"
        findbytes "${libhw}.bak"
        if [[ $bytes =~ 752[0-9] ]]; then
            echo -e "Backup file is okay."
        else
            hexstring="80 3E 00 B8 01 00 00 00 90 90 48 8B"
            findbytes "${libhw}.bak"
            if [[ $bytes == "9090" ]]; then
                echo -e "${Red}Backup file has been edited!${Off}"
            else
                echo -e "${Red}hex string not found!${Off}"
                err=1
            fi
        fi
    else
        echo "No backup file found."
    fi
    exit "$err"
fi

#----------------------------------------------------------
# Backup libhwcontrol (timestamp + .bak symlink)

backup_file="${libhw}.bak.${backup_timestamp}"
if [[ $dryrun == "yes" ]]; then
    echo -e "${Cyan}[DRY RUN]${Off} Would create backup: $(basename -- "$backup_file")"
    echo -e "${Cyan}[DRY RUN]${Off} Would link: $(basename -- "${libhw}.bak") -> $(basename -- "$backup_file")"
else
    if cp -p "$libhw" "$backup_file" ; then
        echo "Backup created: $(basename -- "$backup_file")"
    else
        ding
        echo -e "${Error}ERROR${Off} Backup failed!"
        exit 1
    fi
    rm -f "${libhw}.bak"
    ( cd "$(dirname "$libhw")" && ln -sf "$(basename -- "$backup_file")" "$(basename -- "${libhw}.bak")" )
    echo "Latest backup linked as: $(basename -- "${libhw}.bak")"
fi

#----------------------------------------------------------
# Edit libhwcontrol

hexstring="80 3E 00 B8 01 00 00 00 90 90 48 8B"
findbytes "$libhw"
if [[ $bytes == "9090" ]]; then
    echo -e "\nNon-Synology drive support already enabled."
else
    hexstring="80 3E 00 B8 01 00 00 00 75 2. 48 8B"
    findbytes "$libhw"
    if ! [[ $bytes =~ 752[0-9] ]]; then
        ding
        echo -e "\n${Red}hex string not found!${Off}"
        exit 1
    fi

    if [[ $dryrun == "yes" ]]; then
        echo -e "\n${Cyan}[DRY RUN]${Off} Would edit $(basename -- "$libhw")"
        echo -e "${Cyan}[DRY RUN]${Off} Would replace bytes at position 0x${poshex}+8: $bytes -> 9090"
        echo -e "${Cyan}[DRY RUN]${Off} Would enable non-Synology drive support"
        echo -e "${Cyan}[DRY RUN]${Off} System reboot would be required"
        reboot="yes"
    else
        posrep=$(printf "%x\n" $((0x${poshex}+8)))
        if ! printf %s "${posrep}: 9090" | xxd -r - "$libhw"; then
            ding
            echo -e "${Error}ERROR${Off} Failed to edit $(basename -- "$libhw")!"
            exit 1
        else
            hexstring="80 3E 00 B8 01 00 00 00 90 90 48 8B"
            findbytes "$libhw"
            if [[ $bytes == "9090" ]]; then
                echo -e "\nEnabled non-Synology drive support."
                reboot="yes"
            fi
        fi
    fi
fi

#------------------------------------------------------------------------------
# Edit /etc.defaults/synoinfo.conf

backup_file="${synoinfo}.bak.${backup_timestamp}"
if [[ $dryrun == "yes" ]]; then
    echo -e "\n${Cyan}[DRY RUN]${Off} Would backup $(basename -- "$synoinfo") as $(basename -- "$backup_file")"
    echo -e "${Cyan}[DRY RUN]${Off} Would link: $(basename -- "${synoinfo}.bak") -> $(basename -- "$backup_file")"
else
    if cp -p "$synoinfo" "$backup_file"; then
        echo -e "\nBacked up $(basename -- "$synoinfo") as $(basename -- "$backup_file")" >&2
        rm -f "${synoinfo}.bak"
        ( cd "$(dirname "$synoinfo")" && ln -sf "$(basename -- "$backup_file")" "$(basename -- "${synoinfo}.bak")" )
    else
        ding
        echo -e "\n${Error}ERROR 5${Off} Failed to backup $(basename -- "$synoinfo")!"
        exit 1
    fi
fi

enabled=""
sbd=support_btrfs_dedupe
stbd=support_tiny_btrfs_dedupe

# Enable dedupe support if needed
setting="$("$SYNOBIN/synogetkeyvalue" "$synoinfo" ${sbd})"
if [[ $tiny != "yes" ]]; then
    if [[ -z $setting || $setting == "no" ]]; then
        if [[ $dryrun == "yes" ]]; then
            echo -e "\n${Cyan}[DRY RUN]${Off} Would set $sbd=yes in $synoinfo"
            echo -e "${Cyan}[DRY RUN]${Off} Would set $sbd=yes in $synoinfo2"
            enabled="yes"
        else
            "$SYNOBIN/synosetkeyvalue" "$synoinfo" "$sbd" yes
            "$SYNOBIN/synosetkeyvalue" "$synoinfo2" "$sbd" yes
            enabled="yes"
        fi
    else
        echo -e "\nBtrfs Data Deduplication already enabled."
    fi
    # Disable tiny if we enabled normal
    if [[ $enabled == "yes" ]]; then
        if grep -Fq "$stbd" "$synoinfo"; then
            if [[ $dryrun == "yes" ]]; then
                echo -e "${Cyan}[DRY RUN]${Off} Would set $stbd=no in $synoinfo"
            else
                "$SYNOBIN/synosetkeyvalue" "$synoinfo" "$stbd" no
            fi
        fi
        if grep -Fq "$stbd" "$synoinfo2"; then
            if [[ $dryrun == "yes" ]]; then
                echo -e "${Cyan}[DRY RUN]${Off} Would set $stbd=no in $synoinfo2"
            else
                "$SYNOBIN/synosetkeyvalue" "$synoinfo2" "$stbd" no
            fi
        fi
    fi
fi

# Enable tiny dedupe support if needed
setting="$("$SYNOBIN/synogetkeyvalue" "$synoinfo" ${stbd})"
if [[ $tiny == "yes" ]]; then
    if [[ -z $setting || $setting == "no" ]]; then
        if [[ $dryrun == "yes" ]]; then
            echo -e "\n${Cyan}[DRY RUN]${Off} Would set $stbd=yes in $synoinfo"
            echo -e "${Cyan}[DRY RUN]${Off} Would set $stbd=yes in $synoinfo2"
            enabled="yes"
        else
            "$SYNOBIN/synosetkeyvalue" "$synoinfo" "$stbd" yes
            "$SYNOBIN/synosetkeyvalue" "$synoinfo2" "$stbd" yes
            enabled="yes"
        fi
    else
        echo -e "\nTiny Btrfs Data Deduplication already enabled."
    fi
    # Disable normal if we enabled tiny
    if [[ $enabled == "yes" ]]; then
        if grep -Fq "$sbd" "$synoinfo"; then
            if [[ $dryrun == "yes" ]]; then
                echo -e "${Cyan}[DRY RUN]${Off} Would set $sbd=no in $synoinfo"
            else
                "$SYNOBIN/synosetkeyvalue" "$synoinfo" "$sbd" no
            fi
        fi
        if grep -Fq "$sbd" "$synoinfo2"; then
            if [[ $dryrun == "yes" ]]; then
                echo -e "${Cyan}[DRY RUN]${Off} Would set $sbd=no in $synoinfo2"
            else
                "$SYNOBIN/synosetkeyvalue" "$synoinfo2" "$sbd" no
            fi
        fi
    fi
fi

# Check if we enabled deduplication
setting="$("$SYNOBIN/synogetkeyvalue" "$synoinfo" ${sbd})"
setting2="$("$SYNOBIN/synogetkeyvalue" "$synoinfo" ${stbd})"
if [[ $enabled == "yes" ]]; then
    if [[ $tiny != "yes" ]]; then
        if [[ $setting == "yes" ]]; then
            echo -e "\nEnabled Btrfs Data Deduplication."
            reload="yes"
        else
            ding
            echo -e "\n${Error}ERROR${Off} Failed to enable Btrfs Data Deduplication!"
        fi
    else
        if [[ $setting2 == "yes" ]]; then
            echo -e "\nEnabled Tiny Btrfs Data Deduplication."
            reload="yes"
        else
            ding
            echo -e "\n${Error}ERROR${Off} Failed to enable Tiny Btrfs Data Deduplication!"
        fi
    fi
fi

#------------------------------------------------------------------------------
# Edit StorageManager UI to show HDD dedupe config (DSM 7.2.1+ only when --hdd)

if [[ -f "$strgmgr" && $hdd == "yes" ]]; then
    if grep -Fq '&&e.dedup_info.show_config_btn' "$strgmgr"; then
        echo ""
        backup_file="${strgmgr}.bak.${backup_timestamp}"
        if [[ $dryrun == "yes" ]]; then
            echo -e "${Cyan}[DRY RUN]${Off} Would backup $(basename -- "$strgmgr") as $(basename -- "$backup_file")"
            echo -e "${Cyan}[DRY RUN]${Off} Would link: $(basename -- "${strgmgr}.$storagemgrver") -> $(basename -- "$backup_file")"
            echo -e "${Cyan}[DRY RUN]${Off} Would remove string: &&e.dedup_info.show_config_btn from $(basename -- "$strgmgr")"
            echo -e "${Cyan}[DRY RUN]${Off} Would enable dedupe config menu for HDDs and 2.5\" SSDs"
            reload="yes"
        else
            if cp -p "$strgmgr" "$backup_file"; then
                echo -e "Backed up $(basename -- "$strgmgr") as $(basename -- "$backup_file")"
                rm -f "${strgmgr}.$storagemgrver"
                ( cd "$(dirname "$strgmgr")" && ln -sf "$(basename -- "$backup_file")" "$(basename -- "${strgmgr}.$storagemgrver")" )
            else
                ding
                echo -e "${Error}ERROR${Off} Failed to backup $(basename -- "$strgmgr")!"
            fi

            sed -i 's/&&e.dedup_info.show_config_btn//g' "$strgmgr"
            if ! grep -Fq '&&e.dedup_info.show_config_btn' "$strgmgr"; then
                echo -e "Enabled dedupe config menu for HDDs and 2.5\" SSDs."
                reload="yes"
            else
                ding
                echo -e "${Error}ERROR${Off} Failed to enable dedupe config menu for HDDs and 2.5\" SSDs!"
            fi
        fi
    else
        echo -e "\nDedupe config menu for HDDs and 2.5\" SSDs already enabled."
    fi
elif [[ -f "$strgmgr" ]]; then
    if ! grep -Fq '&&e.dedup_info.show_config_btn' "$strgmgr"; then
        echo -e "\nDedupe config menu for HDDs and 2.5\" SSDs is enabled."
    else
        echo -e "\nDedupe config menu for HDDs and 2.5\" SSDs not enabled."
        echo "Run the script with the --hdd option if you want it enabled."
    fi
fi

# Ensure gzip cache updated if present (xpe issue #88)
if [[ -f "${strgmgr}.gz" ]]; then
    if [[ $dryrun == "yes" ]]; then
        echo -e "${Cyan}[DRY RUN]${Off} Would update ${strgmgr}.gz"
    else
        gzip -c "${strgmgr}" > "${strgmgr}.gz"
    fi
fi

#----------------------------------------------------------
# Finished

if [[ $dryrun == "yes" ]]; then
    echo -e "\n${Cyan}=== DRY RUN COMPLETED ===${Off}"
    echo -e "${Cyan}No actual changes were made.${Off}"
    if [[ $reboot == "yes" ]]; then
        echo -e "${Cyan}Note: System reboot would be required after real execution.${Off}"
    elif [[ $reload == "yes" ]]; then
        echo -e "${Cyan}Note: Browser reload would be required after real execution.${Off}"
    fi
    echo -e "\nTo execute these changes, run the script without --dry-run option."
elif [[ $reboot == "yes" ]]; then
    rebootmsg
elif [[ $reload == "yes" ]]; then
    reloadmsg
else
    echo -e "\nFinished"
fi

exit

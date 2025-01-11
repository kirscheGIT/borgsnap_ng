#!/bin/sh
# cfg_file_hdlr.sh  - licensed under GPLv3. See the LICENSE file for additional
# details.
# shellcheck disable=SC3043
if [ -z "${BORG_HDLR_SOURCED+x}" ]; then
    export BORG_HDLR_SOURCED=1  
    
    . "$(pwd)"/common/msg_and_err_hdlr.sh
    
    if [ -z "${LASTFUNC+x}" ]; then
        export LASTFUNC=""
    fi

    if [ -z "${MSG_DEFINED+x}" ]; then
        msg() {
            LASTFUNC="msg"
            printf "WARNING: msg() function called without invoking the debugging.sh script or explicit disabling it!\n"
            printf "WARNING: No debug or verbose message outputs available!\n"
            return 0
        }
        export MSG_DEFINED=1
    fi

    set -u
    msg "DEBUG" "-----------------------------------------------"
    msg "DEBUG" "sourced borg_hdlr.sh"
    msg "DEBUG" "-----------------------------------------------"
    
   
    
    initBorg(){
        # $1 - mandatory list of repo paths
        # $2 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!

        LASTFUNC="initBorg"
        initBorg_OLD_IFS="$IFS"
        IFS=' '
        initBorg_pathlist="$1"
        initBorg_borgpath="$2"
        
        initBorg_remotepath=""

        if [ -n "$initBorg_borgpath" ]; then
            msg "borgpath set"
            initBorg_remotepath="--remote-path="${initBorg_borgpath}
        else
            msg "borgpath not set - default to borg"
            initBorg_remotepath="--remote-path=borg"
        fi

        for i in $initBorg_pathlist; do
            msg "DEBUG" "Init Borg path is: $i "
            if [ "${i#ssh://}" != "$i" ]; then
                msg "DEBUG" "Initialize Remote path"
                exec_cmd borg init --encryption=repokey "$initBorg_remotepath" "$i"
                  
                #set -e
            else
                exec_cmd borg init --encryption=repokey "$i"  
                #set -e
            fi
        done
        IFS="$initBorg_OLD_IFS"
        unset initBorg_borgpath
        unset initBorg_remotepath
        unset initBorg_pathlist
        return 0
    }

    createBorg(){
        # $1 - mandatory list of repo paths
        # $2 - mandatory label of the backup
        # $3 - mandatory borg options like compression etc. 
        #      valid for all repos in the list
        # $4 - backup source path 
        # $5 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!

        LASTFUNC="createBorg"
        crtBorg_msglevel="$MSG_LEVEL"
        MSG_LEVEL=5
        crtBorg_OLD_IFS="$IFS"
        IFS=' '
        crtBorg_pathlist="$1"
        crtBorg_backuplabel="$2"
        crtBorg_borgopts="$3"
        crtBorg_srcpath="$4"
        crtBorg_borgpath="$5"
        crtBorg_remotepath=""
        crtBorg_cmdline=""

        if [ -n "$crtBorg_borgpath" ]; then
            msg "borgpath set"
            crtBorg_remotepath="--remote-path="${crtBorg_borgpath}
        else
            msg "borgpath not set - default to borg"
            crtBorg_remotepath="--remote-path=borg"
        fi

        for crtBorg_i in $crtBorg_pathlist; do
            if [ "${crtBorg_i#ssh://}" != "$crtBorg_i" ]; then
                # [ ] FIXME #32 source path is wrong @kirscheGIT
                crtBorg_cmdline="borg create $crtBorg_borgopts $crtBorg_remotepath ${crtBorg_i}::${crtBorg_backuplabel} /tmp/borgsnap_ng/" #$crtBorg_srcpath" 
                #exec_cmd borg create "$crtBorg_borgopts" --encryption=repokey"$crtBorg_remotepath" "${crtBorg_i}::${crtBorg_backuplabel}" "$crtBorg_srcpath"
                
                #set -e
            else 
                
                # [ ] TODO #33 use crtBorg_cmdline instead of the below construct @kirscheGIT
                #exec_cmd borg create "$crtBorg_borgopts" --encryption=repokey  "${crtBorg_i}::${crtBorg_backuplabel}" "$crtBorg_srcpath"
                crtBorg_cmdline="borg create $crtBorg_borgopts ${crtBorg_i}::${crtBorg_backuplabel} /tmp/borgsnap_ng/" #$crtBorg_srcpath"  
                #set -e
            fi
            msg "DEBUG" "Borg create cmdline: $crtBorg_cmdline"
            exec_cmd eval "$crtBorg_cmdline"
        done

        MSG_LEVEL=$crtBorg_msglevel
        IFS="$crtBorg_OLD_IFS"
        unset crtBorg_msglevel
        unset crtBorg_cmdline
        unset crtBorg_pathlist
        unset crtBorg_backuplabel
        unset crtBorg_borgopts
        unset crtBorg_borgpath
        unset crtBorg_localpath
        unset crtBorg_remotepath
        return 0

    }

    pruneBorg(){
        # $1 - mandatory list of repo paths
        # $2 - mandatory borg options like compression etc. 
        #      valid for all repos in the list
        # $3 - optional - remote borg command
        #      if multiple remote repos are used, this value
        #      is used for all of them!

        LASTFUNC="createBorg"
        pruneBorg_pathlist="$1"
        pruneBorg_borgopts="$2"
        pruneBorg_compactlabel="$3"
        pruneBorg_borgpath="$4"
        pruneBorg_remotepath=""
        pruneBorg_cmdline=""

        if [ -n "$pruneBorg_borgpath" ]; then
            msg "borgpath set"
            pruneBorg_remotepath="--remote-path="${pruneBorg_borgpath}
        else
            msg "borgpath not set - default to borg"
            pruneBorg_remotepath="--remote-path=borg"
        fi

        # [ ] TODO: #34 Check if statements - could be simplified I guess @kirscheGIT
        for pruneBorg_i in $pruneBorg_pathlist; do
            if [ "${pruneBorg_i#ssh://}" != "$pruneBorg_i" ]; then
                
                pruneBorg_cmdline="borg prune $pruneBorg_borgopts $pruneBorg_remotepath ${pruneBorg_i}"
                #exec_cmd borg prune "$pruneBorg_borgopts" "$pruneBorg_remotepath" "${pruneBorg_i}"
                exec_cmd eval $pruneBorg_cmdline
                if [ "$pruneBorg_compactlabel" = "monthly" ]; then
                    pruneBorg_cmdline="borg compact ${pruneBorg_i}"
                    exec_cmd eval $pruneBorg_cmdline
                fi  
                #set -e
            else 
                pruneBorg_cmdline="borg prune $pruneBorg_borgopts ${pruneBorg_i}"
                #exec_cmd borg prune "$pruneBorg_borgopts" "${pruneBorg_i}"
                exec_cmd eval $pruneBorg_cmdline
                if [ "$pruneBorg_compactlabel" = "monthly" ]; then
                    pruneBorg_cmdline="borg compact ${pruneBorg_i}"
                    #exec_cmd borg compact "${pruneBorg_i}"
                    exec_cmd eval $pruneBorg_cmdline
                fi    
                #set -e
            fi
        done
                
        unset pruneBorg_cmdline
        unset pruneBorg_pathlist
        unset pruneBorg_borgopts
        unset pruneBorg_borgpath
        unset pruneBorg_remotepath
        return 0
    }

fi
#!/bin/sh
# dir_functions.sh is part of borgsnap_ng - licensed under GPLv3. See the LICENSE file for additional
# details.

# shellcheck disable=SC3043
if [ -z "${REMOTE_DIR_FUNCTION_SCRIPT_SOURCED+x}" ]; then
    export REMOTE_DIR_FUNCTION_SCRIPT_SOURCED=1    
    set +e
    #set -x
    . "$(pwd)"/common/msg_and_err_hdlr.sh # [X] TODO #25 Wrong path @kirscheGIT
    
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
    
    msg "DEBUG" "-----------------------------------------------"
    msg "DEBUG" "sourced dir_functions.sh"
    msg "DEBUG" "-----------------------------------------------"
    


    direxists(){
        # $1 - target directory to be created
        # Strings that work at exampel:
        # for local directories  /tmp/test
        # for remote directories ssh://my_ssh_borg_server/dir0/dataset
        LASTFUNC="direxists"
        dirExists_testdir="$1"
        dirExists_remotessh=""
        dirExists_chkpath=""
        dirExists_chkcmd=""

        if [ -z "$dirExists_testdir" ]; then
            msg "ERROR" "Empty directory string was given!"
            return 2
        fi

        if [ "${dirExists_testdir#ssh://}" != "$dirExists_testdir" ]; then
            # Remove "ssh://" from the string
            dirExists_chkpath="${dirExists_testdir#ssh://}"
            dirExists_remotessh="${dirExists_chkpath%%/*}"
            dirExists_chkpath="${dirExists_chkpath#*/}"
            dirExists_chkpath="/$dirExists_chkpath"
            dirExists_chkcmd="ssh $dirExists_remotessh ls"; 
        else
            msg "DEBUG" "Local directory to test is: $dirExists_testdir"
            dirExists_chkpath=$dirExists_testdir
            dirExists_chkcmd="ls ";
        fi

        msg "DEBUG" "Checkcmd is $dirExists_chkcmd"
        msg "DEBUG" "Checkpath is $dirExists_chkpath"

        if  $dirExists_chkcmd "$dirExists_chkpath" > /dev/null 2>&1; then
            msg "INFO" "Directory $dirExists_chkpath - exist"
            set +x
            unset dirExists_remotessh
            unset dirExists_remotedir
            unset dirExists_chkpath
            unset dirExists_chkcmd
            return 0
        else
            msg "INFO" "Directory $dirExists_chkpath doesn't exist"
            set +x
            unset dirExists_remotessh
            unset dirExists_remotedir
            unset dirExists_chkpath
            unset dirExists_chkcmd
            return 1
        fi
    }
    
    dircreate() {
        # $1 - target directory to be created
        # Strings that work at exampel:
        # for local directories  /tmp/test
        # for remote directories ssh://my_ssh_borg_server/dir0/dataset
        LASTFUNC="dircreate"
        dirCreate_tgtdir="$1"
        dirCreate_crtpath=""
        dirCreate_crtcmd=""
        dirCreate_remotessh=""
        
        
         if [ -z "$dirCreate_tgtdir" ]; then
            msg "ERROR" "Empty directory string was given!"
            return 2
        fi
        

        if [ "${dirCreate_tgtdir#ssh://}" != "$dirCreate_tgtdir" ]; then
            # Remove "ssh://" from the path string
            dirCreate_crtpath="${dirCreate_tgtdir#ssh://}"
            # Get the first part of the ssh:// string
            dirCreate_remotessh="${dirCreate_crtpath%%/*}"
            # build the correct tgt path 
            dirCreate_crtpath="${dirCreate_crtpath#*/}"
            dirCreate_crtpath="/$dirCreate_crtpath"
            dirCreate_crtcmd="ssh $dirCreate_remotessh mkdir -p"; 
        else
            msg "DEBUG" "Local directory to test is: $dirCreate_tgtdir"
            dirCreate_crtpath=$dirCreate_tgtdir
            dirCreate_crtcmd="mkdir -p ";
        fi

        #msg "DEBUG" "Remote dir is $lremotedir"
        #msg "DEBUG" "Dataset dir is $ldataset"
        #lcreatepath="/$lremotedir/$ldataset"
        msg "INFO" "Creating Path at path $dirCreate_crtpath"
        msg "INFO" "Create command is $dirCreate_crtcmd"
        # when the ssh mkdir fails, we need the error handler
        
        # because the expansion won't work otherwise, we need to disable the
        # check for the next line
        # shellcheck disable=SC2086
        exec_cmd $dirCreate_crtcmd "$dirCreate_crtpath"

        unset dirCreate_tgtdir
        unset dirCreate_crtpath
        unset dirCreate_remotessh
        unset dirCreate_crtcmd
        
        return 0
    }
fi
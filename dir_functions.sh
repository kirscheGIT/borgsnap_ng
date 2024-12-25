#!/bin/sh
# dir_functions.sh is part of borgsnap_ng - licensed under GPLv3. See the LICENSE file for additional
# details.

# shellcheck disable=SC3043
if [ -z "${REMOTE_DIR_FUNCTION_SCRIPT_SOURCED+x}" ]; then
    export REMOTE_DIR_FUNCTION_SCRIPT_SOURCED=1    
    set +e
    #set -x
    . ./msg_and_err_hdlr.sh
    
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
    msg "DEBUG" "sourced checkdirexists.sh"
    msg "DEBUG" "-----------------------------------------------"
    
    direxists(){
        # $1 - target directory to be created
        # Strings that work at exampel:
        # for local directories  /tmp/test
        # for remote directories ssh://my_ssh_borg_server/dir0/dataset
        LASTFUNC="direxists"
        ltestdir="$1"
        lremotessh=""
        lchkpath=""
        lchkcmd=""

        if [ -z "$ltestdir" ]; then
            msg "ERROR" "Empty directory string was given!"
            return 2
        fi

        if [ "${ltestdir#ssh://}" != "$ltestdir" ]; then
            # Remove "ssh://" from the string
            lchkpath="${ltestdir#ssh://}"
            lremotessh="${lchkpath%%/*}"
            lchkpath="${lchkpath#*/}"
            lchkpath="/$lchkpath"
            lchkcmd="ssh $lremotessh ls"; 
        else
            msg "DEBUG" "Local directory to test is: $ltestdir"
            lchkpath=$ltestdir
            lchkcmd="ls ";
        fi

        msg "DEBUG" "Checkcmd is $lchkcmd"
        msg "DEBUG" "Checkpath is $lchkpath"

        if  $lchkcmd "$lchkpath" > /dev/null 2>&1; then
            msg "INFO" "Directory $lchkpath - exist"
            set +x
            unset lremotessh
            unset lremotedir
            unset lchkpath
            unset lchkcmd
            return 0
        else
            msg "INFO" "Directory $lchkpath doesn't exist"
            set +x
            unset lremotessh
            unset lremotedir
            unset lchkpath
            unset lchkcmd
            return 1
        fi
    }
    
    dircreate() {
        # $1 - target directory to be created
        # Strings that work at exampel:
        # for local directories  /tmp/test
        # for remote directories ssh://my_ssh_borg_server/dir0/dataset
        LASTFUNC="dircreate"
        ltgtdir="$1"
        lcrtpath=""
        lcrtcmd=""
        lremotessh=""
        
        
         if [ -z "$ltgtdir" ]; then
            msg "ERROR" "Empty directory string was given!"
            return 2
        fi
        

        if [ "${ltgtdir#ssh://}" != "$ltgtdir" ]; then
            # Remove "ssh://" from the path string
            lcrtpath="${ltgtdir#ssh://}"
            # Get the first part of the ssh:// string
            lremotessh="${lcrtpath%%/*}"
            # build the correct tgt path 
            lcrtpath="${lcrtpath#*/}"
            lcrtpath="/$lcrtpath"
            lcrtcmd="ssh $lremotessh mkdir -p"; 
        else
            msg "DEBUG" "Local directory to test is: $ltgtdir"
            lcrtpath=$ltgtdir
            lcrtcmd="mkdir -p ";
        fi

        #msg "DEBUG" "Remote dir is $lremotedir"
        #msg "DEBUG" "Dataset dir is $ldataset"
        #lcreatepath="/$lremotedir/$ldataset"
        msg "INFO" "Creating Path at path $lcrtpath"
        msg "INFO" "Create command is $lcrtcmd"
        # when the ssh mkdir fails, we need the error handler
        
        # because the expansion won't work otherwise, we need to disable the
        # check for the next line
        # shellcheck disable=SC2086
        exec_cmd $lcrtcmd "$lcrtpath"

        unset ltgtdir
        unset lcrtpath
        unset lremotessh
        unset lcrtcmd
        
        return 0
    }
fi
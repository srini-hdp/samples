#!/usr/bin/env bash
# This script setups docker, then create a container(s), and install ambari-server
#
# Steps:
# 1. Install OS. Recommend Ubuntu 14.x
# 2. sudo -i    (TODO: only root works at this moment)
# 3. (optional) screen
# 4. wget https://raw.githubusercontent.com/hajimeo/samples/master/bash/start_hdp.sh -O ./start_hdp.sh
# 5. chmod u+x ./start_hdp.sh
# 6. ./start_hdp.sh -i    or './start_hdp.sh -a' for full automated installation
# 7. answer questions
#
# Once setup, just run './start_hdp.sh -s' to start service if server is rebooted
#
# Rules:
# 1. Function name needs to start with f_ or p_
# 2. Function arguments need to use local and start with _
# 3. Variable name which stores user response needs to start with r_
# 4. (optional) __doc__ local variable is for function usage/help
#
# Misc.:
# for i in {1..3}; do echo "# ho-ubu0$i";ssh root@ho-ubu0$i 'grep -E "^(r_AMBARI_VER|r_HDP_REPO_VER)=" *.resp'; done
#
# @author hajime
#

### OS/shell settings
shopt -s nocasematch
#shopt -s nocaseglob
set -o posix
#umask 0000


usage() {
    echo "HELP/USAGE:"
    echo "This script is for setting up this host for HDP or start HDP services.
For security related helper functions, check setup_security.sh.

How to run initial set up:
    ./${g_SCRIPT_NAME} -i [-r=some_file_name.resp]

    or, Auto setup with default response answers

    ./${g_SCRIPT_NAME} -a

How to start containers and Ambari and HDP services:
    ./${g_SCRIPT_NAME} -s [-r=some_file_name.resp]

How to run a function:
    ./${g_SCRIPT_NAME} -f some_function_name

    or

    . ./${g_SCRIPT_NAME}
    f_loadResp              # loading your response which is required for many functions
    some_function_name

Available options:
    -i    Initial set up this host for HDP

    -s    Start HDP services (default)

    -r=response_file_path
          To reuse your previously saved response file.

    -f=function_name
          To run particular function (ex: f_log_cleanup in crontab)

    -U    Skip Update check (for batch mode or cron)

    -h    Show this message.
"
    echo "Available functions:"
    list
}

# Global variables
g_SCRIPT_NAME="start_hdp.sh"
g_SCRIPT_BASE=`basename $g_SCRIPT_NAME .sh`
g_DEFAULT_RESPONSE_FILEPATH="./${g_SCRIPT_BASE}.resp"
g_LATEST_RESPONSE_URL="https://raw.githubusercontent.com/hajimeo/samples/master/misc/latest_hdp.resp"
g_BACKUP_DIR="$HOME/.build_script/"
g_DOCKER_BASE="hdp/base"
g_UNAME_STR="`uname`"
g_DEFAULT_PASSWORD="hadoop"
g_NODE_HOSTNAME_PREFIX="node"
g_DNS_SERVER="localhost"
g_APT_UPDATE_DONE=""

__PID="$$"
__LAST_ANSWER=""

### Procedure type functions

function p_interview() {
    local __doc__="Asks user questions. (Requires Python)"
    # Default values TODO: need to update this part manually
    local _centos_version="6.8"
    local _ambari_version="2.4.2.0"
    local _stack_version="2.5"
    local _hdp_version="${_stack_version}.0.0"

    local _stack_version_full="HDP-$_stack_version"
    local _hdp_repo_url=""

    # TODO: Not good place to install package
    if ! which python &>/dev/null ; then
        _warn "Python is required for interview mode. Installing..."
        _isYes "$g_APT_UPDATE_DONE" || apt-get update && g_APT_UPDATE_DONE="Y"
        apt-get install python -y
    fi

    _ask "Run apt-get upgrade before setting up?" "N" "r_APTGET_UPGRADE" "N"
    _ask "Keep running containers when you start this script with another response file?" "N" "r_DOCKER_KEEP_RUNNING" "N"
    _ask "NTP Server" "ntp.ubuntu.com" "r_NTP_SERVER" "N" "Y"
    # TODO: Changing this IP later is troublesome, so need to be careful
    local _docker_ip=`f_docker_ip "172.17.0.1"`
    _ask "First 24 bits (xxx.xxx.xxx.) of docker container IP Address" "172.17.100." "r_DOCKER_NETWORK_ADDR" "N" "Y"
    _ask "Network Mask (/16 or /24) for docker containers" "/16" "r_DOCKER_NETWORK_MASK" "N" "Y"
    _ask "IP address for docker0 interface" "$_docker_ip" "r_DOCKER_HOST_IP" "N" "Y"
    _ask "Domain Suffix for docker containers" ".localdomain" "r_DOMAIN_SUFFIX" "N" "Y"
    _ask "Container OS type (small letters)" "centos" "r_CONTAINER_OS" "N" "Y"
    if [ -n "$r_CONTAINER_OS" ]; then
        r_CONTAINER_OS="`echo "$r_CONTAINER_OS" | tr '[:upper:]' '[:lower:]'`"
    fi
    _ask "Container OS version" "$_centos_version" "r_CONTAINER_OS_VER" "N" "Y"
    r_REPO_OS_VER="${r_CONTAINER_OS_VER%%.*}"
    _ask "DockerFile URL or path" "https://raw.githubusercontent.com/hajimeo/samples/master/docker/DockerFile" "r_DOCKERFILE_URL" "N" "N"
    _ask "Hostname for docker host in docker private network?" "dockerhost1" "r_DOCKER_PRIVATE_HOSTNAME" "N" "Y"
    #_ask "Username to mount VM host directory for local repo (optional)" "$SUDO_UID" "r_VMHOST_USERNAME" "N" "N"
    _ask "How many nodes (docker containers) creating?" "4" "r_NUM_NODES" "N" "Y"
    _ask "Node starting number (hostname will be sequential from this nubmer)" "1" "r_NODE_START_NUM" "N" "Y"
    _ask "Node hostname prefix" "$g_NODE_HOSTNAME_PREFIX" "r_NODE_HOSTNAME_PREFIX" "N" "Y"
    _ask "DNS Server (Note: Remote DNS requires password less ssh)" "$g_DNS_SERVER" "r_DNS_SERVER" "N" "Y"

    # Questions to install Ambari
    _ask "Avoid installing Ambari? (to create just containers)" "N" "r_AMBARI_NOT_INSTALL"
    if ! _isYes "$r_AMBARI_NOT_INSTALL"; then
        _ask "Ambari server hostname" "${r_NODE_HOSTNAME_PREFIX}${r_NODE_START_NUM}${r_DOMAIN_SUFFIX}" "r_AMBARI_HOST" "N" "Y"
        _ask "Ambari version (used to build repo URL)" "$_ambari_version" "r_AMBARI_VER" "N" "Y"
        _echo "If you have set up a Local Repo, please change below"
        _ask "Ambari repo file URL or path" "http://public-repo-1.hortonworks.com/ambari/${r_CONTAINER_OS}${r_REPO_OS_VER}/2.x/updates/${r_AMBARI_VER}/ambari.repo" "r_AMBARI_REPO_FILE" "N" "Y"
        if _isUrlButNotReachable "$r_AMBARI_REPO_FILE" ; then
            while true; do
                _warn "URL: $r_AMBARI_REPO_FILE may not be reachable."
                _ask "Would you like to re-type?" "Y"
                if ! _isYes ; then break; fi
                _ask "Ambari repo file URL or path" "" "r_AMBARI_REPO_FILE" "N" "Y"
             done
        fi
        # http://public-repo-1.hortonworks.com/ARTIFACTS/jdk-8u112-linux-x64.tar.gz to /var/lib/ambari-server/resources/jdk-8u112-linux-x64.tar.gz
        _ask "Ambari JDK URL (optional)" "" "r_AMBARI_JDK_URL"
        # http://public-repo-1.hortonworks.com/ARTIFACTS/jce_policy-8.zip to /var/lib/ambari-server/resources/jce_policy-8.zip
        _ask "Ambari JCE URL (optional)" "" "r_AMBARI_JCE_URL"

        wget -q -t 1 http://public-repo-1.hortonworks.com/HDP/hdp_urlinfo.json -O /tmp/hdp_urlinfo.json
        if [ -s /tmp/hdp_urlinfo.json ]; then
            _stack_version_full="`cat /tmp/hdp_urlinfo.json | python -c "import sys,json,pprint;a=json.loads(sys.stdin.read());ks=a.keys();ks.sort();print ks[-1]"`"
            _stack_version="`echo $_stack_version_full | cut -d'-' -f2`"
            _hdp_repo_url="`cat /tmp/hdp_urlinfo.json | python -c 'import sys,json,pprint;a=json.loads(sys.stdin.read());print a["'${_stack_version_full}'"]["latest"]["'${r_CONTAINER_OS}${r_REPO_OS_VER}'"]'`"
            _hdp_version="`basename ${_hdp_repo_url%/}`"
        fi

        _ask "Stack Version" "$_stack_version" "r_HDP_STACK_VERSION" "N" "Y"
        if [ "$_stack_version" != "$r_HDP_STACK_VERSION" ]; then _hdp_version="${r_HDP_STACK_VERSION}.0.0"; fi
        _ask "HDP Version for repository" "$_hdp_version" "r_HDP_REPO_VER" "N" "Y"

        _ask "Would you like to set up a local repo for HDP? (may take long time to downlaod)" "N" "r_HDP_LOCAL_REPO"
        if _isYes "$r_HDP_LOCAL_REPO"; then
            _ask "Local repository directory (Apache root)" "/var/www/html/hdp" "r_HDP_REPO_DIR"
            _ask "URL for HDP repo tar.gz file" "http://public-repo-1.hortonworks.com/HDP/${r_CONTAINER_OS}${r_REPO_OS_VER}/2.x/updates/${r_HDP_REPO_VER}/HDP-${r_HDP_REPO_VER}-${r_CONTAINER_OS}${r_REPO_OS_VER}-rpm.tar.gz" "r_HDP_REPO_TARGZ"
            _ask "URL for UTIL repo tar.gz file" "http://public-repo-1.hortonworks.com/HDP-UTILS-1.1.0.20/repos/${r_CONTAINER_OS}${r_REPO_OS_VER}/HDP-UTILS-1.1.0.20-${r_CONTAINER_OS}${r_REPO_OS_VER}.tar.gz" "r_HDP_REPO_UTIL_TARGZ"
        fi

        _ask "HDP Repo URL" "http://public-repo-1.hortonworks.com/HDP/${r_CONTAINER_OS}${r_REPO_OS_VER}/2.x/updates/${r_HDP_REPO_VER}/" "r_HDP_REPO_URL" "N" "Y"    fi
        if _isUrlButNotReachable "${r_HDP_REPO_URL%/}/hdp.repo" ; then
            while true; do
                _warn "URL: $r_HDP_REPO_URL may not be reachable."
                _ask "Would you like to re-type?" "Y"
                if ! _isYes ; then break; fi
                _ask "HDP Repo URL" "" "r_HDP_REPO_URL" "N" "Y"
             done
        fi

        _ask "Would you like to use Ambari Blueprint?" "Y" "r_AMBARI_BLUEPRINT"
        if _isYes "$r_AMBARI_BLUEPRINT"; then
            _ask "Cluster name" "c${r_NODE_START_NUM}" "r_CLUSTER_NAME" "N" "Y"
            _ask "Default password" "$g_DEFAULT_PASSWORD" "r_DEFAULT_PASSWORD" "N" "Y"
            _ask "Host mapping json path (optional)" "" "r_AMBARI_BLUEPRINT_HOSTMAPPING_PATH"
            _ask "Cluster config json path (optional)" "" "r_AMBARI_BLUEPRINT_CLUSTERCONFIG_PATH"
        fi

        #_ask "Would you like to increase Ambari Alert interval?" "Y" "r_AMBARI_ALERT_INTERVAL"
    fi

    _ask "Would you like to set up a proxy server for yum on this server?" "Y" "r_PROXY"
    if _isYes "$r_PROXY"; then
        _ask "Proxy port" "28080" "r_PROXY_PORT"
    fi
}

function p_interview_or_load() {
    local __doc__="Asks user to start interview, review interview, or start installing with given response file."

    if _isUrl "${_RESPONSE_FILEPATH}"; then
        if [ -s "$g_DEFAULT_RESPONSE_FILEPATH" ]; then
            local _new_resp_filepath="./`basename $_RESPONSE_FILEPATH`"
        else
            local _new_resp_filepath="$g_DEFAULT_RESPONSE_FILEPATH"
        fi
        wget -nv "${_RESPONSE_FILEPATH}" -O ${_new_resp_filepath}
        _RESPONSE_FILEPATH="${_new_resp_filepath}"
    fi

    if [ -r "${_RESPONSE_FILEPATH}" ]; then
        _info "Loading ${_RESPONSE_FILEPATH}..."
        f_loadResp

        # if auto setup, just load and exit
        if _isYes "$_AUTO_SETUP_HDP"; then
            return 0
        fi

        _ask "Would you like to review your responses?" "Y"
        # if don't want to review, just load and exit
        if ! _isYes; then
            return 0
        fi
    fi

    _info "Starting Interview mode..."
    _info "You can stop this interview anytime by pressing 'Ctrl+c' (except while typing secret/password)."
    echo ""

    trap '_cancelInterview' SIGINT
    while true; do
        p_interview

        _info "Interview completed."
        _ask "Would you like to save your response?" "Y"
        if ! _isYes; then
            _ask "Would you like to re-do the interview?" "Y"
            if ! _isYes; then
                _echo "Continuing without saving..."
                break
            fi
        else
            break
        fi
    done
    trap - SIGINT

    f_saveResp
}
function _cancelInterview() {
    echo ""
    echo ""
    echo "Exiting..."
    _ask "Would you like to save your current responses?" "N" "is_saving_resp"
    if _isYes "$is_saving_resp"; then
        f_saveResp
    fi
    _exit
}

function p_hdp_start() {
    f_loadResp
    f_dnsmasq_banner_reset
    f_docker0_setup
    f_ntp
    if ! _isYes "$r_DOCKER_KEEP_RUNNING"; then
        f_docker_stop_other
    fi
    f_docker_start
    sleep 4
    _info "NOT setting up the default GW. please use f_gw_set if necessary"
    #f_gw_set
    #f_etcs_mount

    _info "Starting Ambari Server"
    f_ambari_server_start
    f_ambari_java_random
    # not interested in agent start output at this moment.
    f_run_cmd_on_nodes "ambari-agent start" > /dev/null

    f_log_cleanup

    f_services_start

    f_port_forward 8080 $r_AMBARI_HOST 8080 "Y"
    f_port_forward_ssh_on_nodes
    f_screen_cmd
}

function p_ambari_blueprint() {
    local __doc__="Build cluster with Ambari Blueprint (expecting agents are already installed and running)"
    local _cluster_name="${1-$r_CLUSTER_NAME}"
    local _hostmap_json="/tmp/${_cluster_name}_hostmap.json"
    local _cluster_config_json="/tmp/${_cluster_name}_cluster_config.json"

    # just in case, try starting server
    f_ambari_server_start
    _port_wait "$r_AMBARI_HOST" "8080" || return 1

    local _c="`f_get_cluster_name`"
    if [ "$_c" = "$_cluster_name" ]; then
        _warn "Cluster name $_cluster_name already exists in Ambari. Skipping..."
        return 1
    fi

    if [ ! -z "$r_AMBARI_BLUEPRINT_HOSTMAPPING_PATH" ]; then
        _hostmap_json="$r_AMBARI_BLUEPRINT_HOSTMAPPING_PATH"
        if [ ! -s "$_hostmap_json" ]; then
            _warn "$_hostmap_json does not exist or empty file. Will regenerate automatically..."
            f_ambari_blueprint_hostmap > $_hostmap_json
        fi
    else
        f_ambari_blueprint_hostmap > $_hostmap_json
    fi

    if [ ! -z "$r_AMBARI_BLUEPRINT_CLUSTERCONFIG_PATH" ]; then
        _cluster_config_json="$r_AMBARI_BLUEPRINT_CLUSTERCONFIG_PATH"
        if [ ! -s "$_cluster_config_json" ]; then
            _warn "$_cluster_config_json does not exist or empty file. Will regenerate automatically..."
            f_ambari_blueprint_cluster_config > $_cluster_config_json
        fi
    else
        f_ambari_blueprint_cluster_config > $_cluster_config_json
    fi

    curl -H "X-Requested-By: ambari" -X POST -u admin:admin "http://$r_AMBARI_HOST:8080/api/v1/blueprints/$_cluster_name" -d @${_cluster_config_json} || return $?
    curl -H "X-Requested-By: ambari" -X POST -u admin:admin "http://$r_AMBARI_HOST:8080/api/v1/clusters/$_cluster_name" -d @${_hostmap_json} || return $?
}

function f_ambari_blueprint_hostmap() {
    local __doc__="Output json string for Ambari Blueprint Host mapping"
    #local _cluster_name="${1-$r_CLUSTER_NAME}"
    local _default_password="${1-$r_DEFAULT_PASSWORD}"
    local _is_kerberos_on="$2"
    local _how_many="${3-$r_NUM_NODES}"
    local _start_from="${4-$r_NODE_START_NUM}"
    local _domain_suffix="${5-$r_DOMAIN_SUFFIX}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    local _host_loop=""
    local _num=1
    for i in `_docker_seq "$_how_many" "$_start_from"`; do
        _host_loop="${_host_loop}
    {
      \"name\" : \"host_group_$_num\",
      \"hosts\" : [
        {
          \"fqdn\" : \"${_node}$i${_domain_suffix}\"
        }
      ]
    },"
    _num=$((_num+1))
    done
    _host_loop="${_host_loop%,}"

    # TODO: Kerboers https://cwiki.apache.org/confluence/display/AMBARI/Blueprints#Blueprints-BlueprintExample:ProvisioningMulti-NodeHDP2.3ClustertouseKERBEROS
    local _kerberos_config=''
    if _isYes "$_is_kerberos_on"; then
        _kerberos_config=',
  "credentials" : [
    {
      "alias" : "kdc.admin.credential",
      "principal" : "admin/admin",
      "key" : "'$_default_password'",
      "type" : "TEMPORARY"
    }
  ],
  "security" : {
     "type" : "KERBEROS"
  }
'
    fi

    echo "{
  \"blueprint\" : \"multinode-hdp\",
  \"default_password\" : \"$_default_password\",
  \"host_groups\" :["
    echo "$_host_loop"
    echo "  ]${_kerberos_config}
}"
    # NOTE: It seems blueprint works without "Clusters"
    #  , \"Clusters\" : {\"cluster_name\":\"${_cluster_name}\"}
}

function f_ambari_blueprint_cluster_config() {
    local __doc__="Output json string for Ambari Blueprint Cluster mapping TODO: it's fixed map at this moment"
    local _stack_version="${1-$r_HDP_STACK_VERSION}"
    local _is_kerberos_on="$2"
    local _how_many="${3-$r_NUM_NODES}"

    if [ -z "$_how_many" ] || [ 4 -gt "$_how_many" ]; then
        _error "At this moment, Blueprint build needs at least 4 nodes"
        return 1
    fi

    # TODO: Realm is hardcoded (and kdc_host)
    local _kerberos_client=""
    local _security="";
    local _kerberos_config=""
    if _isYes "$_is_kerberos_on"; then
        _kerberos_client=',
        {
          "name" : "KERBEROS_CLIENT"
        }
'
        _security=',
    "security" : {"type" : "KERBEROS"}
'
        _kerberos_config=',
    {
      "kerberos-env": {
        "properties_attributes" : { },
        "properties" : {
          "realm" : "EXAMPLE.COM",
          "kdc_type" : "mit-kdc",
          "kdc_host" : "'$r_AMBARI_HOST'",
          "admin_server_host" : "'$r_AMBARI_HOST'"
        }
      }
    },
    {
      "krb5-conf": {
        "properties_attributes" : { },
        "properties" : {
          "domains" : "EXAMPLE.COM",
          "manage_krb5_conf" : "true"
        }
      }
    }
'
    fi


    echo '{
  "configurations" : [
    {
      "hadoop-env" : {
        "properties" : {
          "dtnode_heapsize" : "512m",
          "namenode_heapsize" : "513m",
          "nfsgateway_heapsize" : "512"
        }
      }
    },
    {
      "hdfs-site" : {
        "properties" : {
          "dfs.replication" : "1",
          "dfs.datanode.du.reserved" : "536870912"
        }
      }
    },
    {
      "yarn-env" : {
        "properties" : {
          "apptimelineserver_heapsize" : "512",
          "resourcemanager_heapsize" : "513",
          "nodemanager_heapsize" : "514"
        }
      }
    },
    {
      "yarn-site" : {
        "properties" : {
          "yarn.scheduler.minimum-allocation-mb" : "256"
        }
      }
    },
    {
      "mapred-env" : {
        "properties" : {
          "jobhistory_heapsize" : "512"
        }
      }
    },
    {
      "mapred-site" : {
        "properties" : {
          "mapreduce.map.memory.mb" : "256",
          "mapreduce.map.java.opts" : "-Xmx202m",
          "mapreduce.reduce.memory.mb" : "256",
          "mapreduce.reduce.java.opts" : "-Xmx203m",
          "yarn.app.mapreduce.am.resource.mb" : "256",
          "yarn.app.mapreduce.am.command-opts" : "-Xmx201m -Dhdp.version=${hdp.version}"
        }
      }
    },
    {
      "tez-site" : {
        "properties" : {
          "tez.am.resource.memory.mb" : "256",
          "tez.task.resource.memory.mb" : "256",
          "tez.runtime.io.sort.mb" : "128"
        }
      }
    },
    {
      "hive-env" : {
        "properties" : {
          "hive.metastore.heapsize" : "512",
          "hive.heapsize" : "513"
        }
      }
    }
  ],
  "host_groups": [
    {
      "name" : "host_group_1",
      "components" : [
        {
          "name" : "AMBARI_SERVER"
        }'${_kerberos_client}'
      ],
      "configurations" : [ ],
      "cardinality" : "1"
    },
    {
      "name" : "host_group_2",
      "components" : [
        {
          "name" : "YARN_CLIENT"
        },
        {
          "name" : "HDFS_CLIENT"
        },
        {
          "name" : "TEZ_CLIENT"
        },
        {
          "name" : "ZOOKEEPER_CLIENT"
        },
        {
          "name" : "PIG"
        },
        {
          "name" : "HIVE_CLIENT"
        },
        {
          "name" : "HIVE_SERVER"
        },
        {
          "name" : "MYSQL_SERVER"
        },
        {
          "name" : "HIVE_METASTORE"
        },
        {
          "name" : "HISTORYSERVER"
        },
        {
          "name" : "NAMENODE"
        },
        {
          "name" : "WEBHCAT_SERVER"
        },
        {
          "name" : "MAPREDUCE2_CLIENT"
        },
        {
          "name" : "APP_TIMELINE_SERVER"
        },
        {
          "name" : "RESOURCEMANAGER"
        }'${_kerberos_client}'
      ],
      "configurations" : [ ],
      "cardinality" : "1"
    },
    {
      "name" : "host_group_3",
      "components" : [
        {
          "name" : "ZOOKEEPER_SERVER"
        },
        {
          "name" : "SECONDARY_NAMENODE"
        }'${_kerberos_client}'
      ],
      "configurations" : [ ],
      "cardinality" : "1"
    },
    {
      "name" : "host_group_4",
      "components" : [
        {
          "name" : "YARN_CLIENT"
        },
        {
          "name" : "HDFS_CLIENT"
        },
        {
          "name" : "TEZ_CLIENT"
        },
        {
          "name" : "ZOOKEEPER_CLIENT"
        },
        {
          "name" : "HCAT"
        },
        {
          "name" : "PIG"
        },
        {
          "name" : "MAPREDUCE2_CLIENT"
        },
        {
          "name" : "HIVE_CLIENT"
        },
        {
          "name" : "NODEMANAGER"
        },
        {
          "name" : "DATANODE"
        }'${_kerberos_client}'
      ],
      "configurations" : [ ],
      "cardinality" : "1"
    }
  ],
  "Blueprints": {
    "blueprint_name": "multinode-hdp",
    "stack_name": "HDP",
    "stack_version": "'$_stack_version'"'${_security}'
  }
}'
}

function f_saveResp() {
    local __doc__="Save current responses(answers) in memory into a file."
    local _file_path="${1-$_RESPONSE_FILEPATH}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    if [ -z "${_file_path}" ]; then
        if [ -n "${r_AMBARI_VER}" ] || [ -n "${r_HDP_REPO_VER}" ]; then
            local _tmp_RESPONSE_FILEPATH="${_node}${r_NODE_START_NUM}_HDP${r_HDP_REPO_VER}_ambari${r_AMBARI_VER}"
            _file_path="${_tmp_RESPONSE_FILEPATH//./}.resp"
        else
            _file_path="$g_DEFAULT_RESPONSE_FILEPATH"
        fi
    fi

    if [ -z "$_file_path" ]; then
        _ask "Response file path" "$g_DEFAULT_RESPONSE_FILEPATH" "_RESPONSE_FILEPATH"
        _file_path="$_RESPONSE_FILEPATH"
    fi

    if [ ! -e "${_file_path}" ]; then
        touch ${_file_path}
    else
        _backup "${_file_path}"
    fi
    
    if [ ! -w "${_file_path}" ]; then
        _critical "$FUNCNAME: Not a writeable response file. ${_file_path}" 1
    fi
    
    # clear file (no warning...)
    cat /dev/null > ${_file_path}
    
    for _v in `set | grep -P -o "^r_.+?[^\s]="`; do
        _new_v="${_v%=}"
        echo "${_new_v}=\"${!_new_v}\"" >> ${_file_path}
    done
    
    # trying to be secure as much as possible
    #if [ -n "$SUDO_USER" ]; then
    #    chown $SUDO_UID:$SUDO_GID ${_file_path}
    #fi
    #chmod 1600 ${_file_path}
    
    _info "Saved ${_file_path}"
}

function f_loadResp() {
    local __doc__="Load responses(answers) from given file path or from default location."
    local _file_path="${1-$_RESPONSE_FILEPATH}"
    local _use_default_resp="$2"

    if [ -z "$_file_path" ]; then
        if _isYes "$_use_default_resp"; then
            _file_path="$g_DEFAULT_RESPONSE_FILEPATH";
        else
            _info "Available response files"
            ls -1t ./*.resp
            local _default_file_path="`ls -1t ./*.resp | head -n1`"
            _file_path=""
            _ask "Type a response file path" "$_default_file_path" "_file_path" "N" "Y"
            _info "Using $_file_path ..."
            _RESPONSE_FILEPATH="$_file_path"
        fi
    fi
    
    if [ ! -r "${_file_path}" ]; then
        _critical "$FUNCNAME: Not a readable response file. ${_file_path}" 1;
        exit 2
    fi
    
    #g_response_file="$_file_path"  TODO: forgot what this line was for
    
    #local _extension="${_actual_file_path##*.}"
    #if [ "$_extension" = "7z" ]; then
    #    local _dir_path="$(dirname ${_actual_file_path})"
    #    cd $_dir_path && 7za e ${_actual_file_path} || _critical "$FUNCNAME: 7za e error."
    #    cd - >/dev/null
    #    _used_7z=true
    #fi
    
    # Note: somehow "source <(...)" does noe work, so that created tmp file.
    grep -P -o '^r_.+[^\s]=\".*?\"' ${_file_path} > /tmp/f_loadResp_${__PID}.out && source /tmp/f_loadResp_${__PID}.out
    
    # clean up
    rm -f /tmp/f_loadResp_${__PID}.out
    touch ${_file_path}
    return $?
}

function f_ntp() {
    local __doc__="Run ntpdate $r_NTP_SERVER"
    _info "ntpdate ..."
    ntpdate -u $r_NTP_SERVER
}

function _docker_seq() {
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _output_cmd="$3"

    if [ -z "$_start_from" ]; then
        _start_from=1
    fi

    if [ -z "$_how_many" ]; then
        _how_many=1
    fi

    if [ $_start_from -lt 1 ]; then
        _warn "Starting from number is not specified."
        return 1
    fi

    local _e=`expr $_start_from + $_how_many - 1`
    if [ $_e -lt 1 ]; then
        _warn "Number of nodes (containers) is not specified."
        return 1
    fi

    if _isYes "$_output_cmd"; then
        echo "seq $_start_from $_e"
    else
        seq $_start_from $_e
    fi
}

function f_docker_setup() {
    local __doc__="Install docker (if not yet) and customise for HDP test environment (TODO: Ubuntu only)"
    # https://docs.docker.com/engine/installation/linux/docker-ce/ubuntu/

    if [ ! `which apt-get` ]; then
        _warn "No apt-get"
        return 1
    fi

    which docker &>/dev/null
    if [ $? -gt 0 ] || [ ! -s /etc/apt/sources.list.d/docker.list ]; then
        apt-get install apt-transport-https ca-certificates -y
        apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D || _info "Did not add key for docker"
        grep -q "deb https://apt.dockerproject.org/repo" /etc/apt/sources.list.d/docker.list || echo "deb https://apt.dockerproject.org/repo ubuntu-`cat /etc/lsb-release | grep CODENAME | cut -d= -f2` main" >> /etc/apt/sources.list.d/docker.list
        apt-get update && apt-get purge lxc-docker*; apt-get install docker-engine -y
    fi

    # To use tcpdump from container
    if [ ! -L /etc/apparmor.d/disable/usr.sbin.tcpdump ]; then
        ln -sf /etc/apparmor.d/usr.sbin.tcpdump /etc/apparmor.d/disable/
        apparmor_parser -R /etc/apparmor.d/usr.sbin.tcpdump
    fi

    local _storage_size="30G"
    # This part is different by docker version, so changing only if it was 10GB or 1*.**GB
    docker info | grep 'Base Device Size' | grep -oP '1\d\.\d\d GB' &>/dev/null
    if [ $? -eq 0 ]; then
        grep 'storage-opt dm.basesize=' /etc/init/docker.conf &>/dev/null
        if [ $? -ne 0 ]; then
            sed -i.bak -e 's/DOCKER_OPTS=$/DOCKER_OPTS=\"--storage-opt dm.basesize='${_storage_size}'\"/' /etc/init/docker.conf
            _warn "Restarting docker (will stop all containers)..."
            sleep 3
            service docker restart
        else
            _warn "storage-opt dm.basesize=${_storage_size} is already set in /etc/init/docker.conf"
        fi
    fi
}

function f_docker0_setup() {
    local __doc__="Setting IP for docker0 to $r_DOCKER_HOST_IP (default)"
    local _docker0="${1}"
    local _mask="${2}"

    [ -z "$_docker0" ] && _docker0="$r_DOCKER_HOST_IP"
    [ -z "$_mask" ] && _mask="$r_DOCKER_NETWORK_MASK"
    _mask="${_mask#/}"

    if ! ifconfig docker0 | grep "$_docker0" &>/dev/null ; then
        local _netmask="255.255.0.0"
        [ "$_mask" = "24" ] && _netmask="255.255.255.0"

        #_info "Setting IP for docker0 to $_docker0/$_netmask ..."
        ifconfig docker0 $_docker0 netmask $_netmask

        if [ -n "$_mask" ]; then
            if [ -f /lib/systemd/system/docker.service ] && which systemctl &>/dev/null ; then
                if ! grep -qE -- '--bip=' /lib/systemd/system/docker.service; then
                    sed -i "/H fd:\/\// s/$/ --bip=${_docker0}\/${_mask}/" /lib/systemd/system/docker.service && systemctl daemon-reload && service docker restart
                elif ! grep -qE -- "--bip=${_docker0}/${_mask}" /lib/systemd/system/docker.service; then
                    sed -i -e "s/--bip=[0-9.\/]\+/--bip=${_docker0}\/${_mask}/" /lib/systemd/system/docker.service && systemctl daemon-reload && service docker restart
                fi
            else
                grep "$_docker0" /etc/default/docker || (echo "DOCKER_OPTS=\"$DOCKER_OPTS --bip=$_docker0$r_DOCKER_NETWORK_MASK\"" >> /etc/default/docker && /etc/init.d/docker restart)  # TODO: untested. May not work with 14.04
            fi
        fi
    fi
}

function f_docker_base_create() {
    local __doc__="Create a docker base image"
    local _docker_file="$1"
    if [ -z "$_docker_file" ]; then
        _docker_file="./DockerFile"
    fi
    if [ ! -r "$_docker_file" ]; then
        _error "$_docker_file is not readable"
        return 1
    fi

    if [ -z "$r_CONTAINER_OS" ]; then
        _error "No container OS specified"
        return 1
    fi
    docker images | grep -P "^${r_CONTAINER_OS}\s+${r_CONTAINER_OS_VER}" || docker pull ${r_CONTAINER_OS}:${r_CONTAINER_OS_VER}
    docker build -t ${g_DOCKER_BASE} -f $_docker_file .
}

function f_docker_start() {
    local __doc__="Starting some docker containers"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    _info "starting $_how_many docker containers starting from $_start_from ..."
    for _n in `_docker_seq "$_how_many" "$_start_from"`; do
        # docker seems doesn't care if i try to start already started one
        docker start --attach=false ${_node}$_n &
        sleep 1
    done
    wait
}

function f_docker_unpause() {
    local __doc__="Experimental: Unpausing some docker containers"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    _info "starting $_how_many docker containers starting from $_start_from ..."
    for _n in `_docker_seq "$_how_many" "$_start_from"`; do
        docker unpause ${_node}$_n
    done
}

function f_docker_stop() {
    local __doc__="Stopping some docker containers"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    _info "stopping $_how_many docker containers starting from $_start_from ..."
    for _n in `_docker_seq "$_how_many" "$_start_from"`; do
        docker stop ${_node}$_n &
        sleep 1
    done
    wait
}

function f_docker_save() {
    local __doc__="Stop containers and commit (save)"
    local _sufix="${1}"
    local _how_many="${2-$r_NUM_NODES}"
    local _start_from="${3-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    _warn "If you have not checked disk space, please Ctrl+C now (wait for 3 secs)..."
    sleep 3

    if [ -z "$_sufix" ]; then
        # once a day should be enough?
        _sufix="$(date +"%Y%m%d")"
    fi

    _info "stopping $_how_many docker containers starting from $_start_from ..."
    f_docker_stop $_how_many $_start_from

    _info "saving $_how_many docker containers starting from $_start_from ..."
    for _n in `_docker_seq "$_how_many" "$_start_from"`; do
        docker commit ${_node}$_n ${_node}${_n}_$_sufix&
        sleep 1
    done
    wait
}

function f_docker_stop_all() {
    local __doc__="Stopping all docker containers if docker command exists"
    if ! which docker &>/dev/null; then
        _info "No docker command found in the path. Not stopping."
        return 0
    fi
    _info "Stopping the followings"
    docker ps
    docker stop $(docker ps -q)
}

function f_docker_stop_other() {
    local __doc__="Stopping other docker containers"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    local _filter=""
    for _s in `_docker_seq "$_how_many" "$_start_from"`; do
        _filter="${_filter}${_node}${_s}|"
    done
    _filter="${_filter%\|}"

    _info "stopping other docker containers (not in ${_filter})..."
    for _n in `docker ps --format "{{.Names}}" | grep -vE "${_filter}"`; do
        docker stop $_n &
        sleep 1
    done
    wait
}

function f_docker_pause_other() {
    local __doc__="Experimental: Pausing(suspending) other docker containers"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    local _filter=""
    for _s in `_docker_seq "$_how_many" "$_start_from"`; do
        _filter="${_filter}${_node}${_s}|"
    done
    _filter="${_filter%\|}"

    _info "stopping other docker containers (not in ${_filter})..."
    for _n in `docker ps --format "{{.Names}}" | grep -vE "${_filter}"`; do
        docker pause $_n &
        sleep 1
    done
    wait
}

function f_docker_rm_all() {
    local _force="$1"
    local __doc__="Removing *all* docker containers"
    _ask "Are you sure to delete ALL containers?" "N"
    if _isYes; then
        if _isYes $_force; then
            for _q in `docker ps -aq`; do
                docker rm --force ${_q} &
                sleep 1
            done
        else
            for _q in `docker ps -aq`; do
                docker rm ${_q} &
                sleep 1
            done
        fi
        wait
    fi
}

function f_docker_run() {
    local __doc__="Running (creating) docker containers"
    # ./start_hdp.sh -r ./node11-14_2.5.0.resp -f "f_docker_run 1 16"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    local _ip="`f_docker_ip`"
    local _dns="${r_DNS_SERVER-$g_DNS_SERVER}"

    if [ $_dns = "localhost" ]; then
        _dns="$_ip"
    fi

    if [ -z "$_ip" ]; then
        _warn "No Docker interface IP"
        return 1
    fi

    local _line=""
    for _n in `_docker_seq "$_how_many" "$_start_from"`; do
        _line="`docker ps -a -f name=${_node}$_n | grep -w ${_node}$_n`"
        if [ -n "$_line" ]; then
            _warn "${_node}$_n already exists. Skipping..."
            continue
        fi
        local _netmask="255.255.0.0"
        if [ "$r_DOCKER_NETWORK_MASK" = "/24" ]; then
            _netmask="255.255.255.0"
        fi
        # --ip may not work due to "docker: Error response from daemon: user specified IP address is supported on user defined networks only."
        docker run -t -i -d --privileged --hostname=${_node}$_n${r_DOMAIN_SUFFIX} --dns=$_dns --name=${_node}$_n ${g_DOCKER_BASE} /startup.sh ${r_DOCKER_NETWORK_ADDR}$_n ${_node}$_n${r_DOMAIN_SUFFIX} $_ip $_netmask
    done
}

function _ambari_query_sql() {
    local _query="${1%\;}"
    local _ambari_host="${2-$r_AMBARI_HOST}"

    PGPASSWORD=bigdata psql -Uambari -h $_ambari_host -tAc "$_query;"
}

function f_get_cluster_name() {
    local __doc__="Output (return) cluster name by using SQL"
    local _ambari_host="${1-$r_AMBARI_HOST}"
    local _c="$(_ambari_query_sql "select cluster_name from ambari.clusters order by cluster_id desc limit 1;" $_ambari_host)"
    if [ -z "$_c" ]; then
        _warn "No cluster name from $_ambari_host"
        return 1
    fi
    echo "$_c"
}

function f_ambari_server_install() {
    local __doc__="Install Ambari Server to $r_AMBARI_HOST"
    if [ -z "$r_AMBARI_REPO_FILE" ]; then
        _error "Please specify Ambari repo *file* URL"
        return 1
    fi

    _port_wait "$r_AMBARI_HOST" "8080" 1
    if [ $? -eq 0 ]; then
        _warn "Something is already listening on $r_AMBARI_HOST:8080"
        return 1
    fi

    # TODO: at this moment, only Centos (yum)
    if _isUrl "$r_AMBARI_REPO_FILE"; then
        wget -nv "$r_AMBARI_REPO_FILE" -O /tmp/ambari.repo || return 1
    else
        if [ ! -r "$r_AMBARI_REPO_FILE" ]; then
            _error "Please specify readable Ambari repo file or URL"
            return 1
        fi

        cp -f "$r_AMBARI_REPO_FILE" /tmp/ambari.repo
    fi

    if _isUrl "$r_AMBARI_JDK_URL"; then
        ssh -q root@$r_AMBARI_HOST "mkdir -p /var/lib/ambari-server/resources/; cd /var/lib/ambari-server/resources/ && curl \"$r_AMBARI_JDK_URL\" -O"
    fi
    if _isUrl "$r_AMBARI_JCE_URL"; then
        ssh -q root@$r_AMBARI_HOST "mkdir -p /var/lib/ambari-server/resources/; cd /var/lib/ambari-server/resources/ && curl \"$r_AMBARI_JCE_URL\" -O"
    fi

    scp -q /tmp/ambari.repo root@$r_AMBARI_HOST:/etc/yum.repos.d/
    ssh -q root@$r_AMBARI_HOST "yum clean all; yum install ambari-server -y && service postgresql initdb && service postgresql restart && for i in {1..3}; do [ -e /tmp/.s.PGSQL.5432 ] && break; sleep 5; done; ambari-server setup -s || ( echo 'ERROR ambari-server setup failed! Trying one more time...'; sed -i.bak '/server.jdbc.database/d' /etc/ambari-server/conf/ambari.properties; ambari-server setup -s --verbose )"
}

function f_ambari_server_start() {
    local __doc__="Starting ambari-server on $r_AMBARI_HOST"
    _port_wait "$r_AMBARI_HOST" "22"
    ssh -q root@$r_AMBARI_HOST "ambari-server start --silent" &> /tmp/f_ambari_server_start.out
    if [ $? -ne 0 ]; then
        grep 'Ambari Server is already running' /tmp/f_ambari_server_start.out && return
        sleep 5
        ssh -q root@$r_AMBARI_HOST "ambari-server start"
    fi
}

function f_port_forward_ssh_on_nodes() {
    local __doc__="Opening SSH ports to each node"
    local _init_port="${1-2200}"
    local _how_many="${2-$r_NUM_NODES}"
    local _start_from="${3-$r_NODE_START_NUM}"
    local _local_port=0
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    for i in `_docker_seq "$_how_many" "$_start_from"`; do
        _local_port=$(($_init_port + $i))
        f_port_forward $_local_port ${_node}$i${r_DOMAIN_SUFFIX} 22
    done
}

function f_port_forward() {
    local __doc__="Port forwarding a local port to a container port"
    local _local_port="$1"
    local _remote_host="$2"
    local _remote_port="$3"
    local _kill_process="$4"

    if [ -z "$_local_port" ] || [ -z "$_remote_host" ] || [ -z "$_remote_port" ]; then
        _error "Local Port or Remote Host or Remote Port is missing."
        return 1
    fi
    local _pid="`lsof -ti:$_local_port`"
    if [ -n "$_pid" ] ; then
        _warn "Local port $_local_port is already used by PID $_pid."
        if _isYes "$_kill_process" ; then
            kill $_pid || return 3
            _info "Killed $_pid."
        else
            return 0
        fi
    fi

    #if ! which socat &>/dev/null ; then
    #    _warn "No socat. Installing"; apt-get install socat -y || return 2
    #fi
    #nohup socat tcp4-listen:$_local_port,reuseaddr,fork tcp:$_remote_host:$_remote_port & TODO: which is better, socat or ssh?
    _info "port-forwarding -L$_local_port:$_remote_host:$_remote_port ..."
    ssh -2CNnqTxfg -L$_local_port:$_remote_host:$_remote_port $_remote_host
}

function f_ambari_update_config() {
    local __doc__="TODO: Change some configuration for this dev environment"
    local _force="$1"

    # TODO: need to find the best way to find the first time
    if ! _isYes "$_force"; then
        local _c="`_ambari_query_sql "select count(*) from alert_definition where schedule_interval = 6;" $r_AMBARI_HOST`"
        if [ 0 -ne $_c ]; then
            _info "Skipping f_ambari_update_config as most likely this has been done."
            return
        fi
    fi

    _info "Reducing Ambari Alert frequency..."
    _ambari_query_sql "update alert_definition set schedule_interval = schedule_interval * 2 where schedule_interval < 11" "$r_AMBARI_HOST"

    #_info "Reducing dfs.replication to 1..."
    #ssh -q -t root@$r_AMBARI_HOST -t "/var/lib/ambari-server/resources/scripts/configs.sh set localhost $r_CLUSTER_NAME hdfs-site dfs.replication 1" &> /tmp/configs_sh_dfs_replication.out
    # TODO: should I reduce aggregator TTL size?

    _info "Modifying postgresql for Ranger install later..."
    ssh -q -t root@$r_AMBARI_HOST -t "ambari-server setup --jdbc-db=postgres --jdbc-driver=\`find /usr/lib/ambari-server/ -name 'postgresql-*.jar' | head -n 1\`
sudo -u postgres psql -c \"CREATE ROLE rangeradmin WITH SUPERUSER LOGIN PASSWORD '${g_DEFAULT_PASSWORD}'\"
grep -w rangeradmin /var/lib/pgsql/data/pg_hba.conf || echo 'host  all   rangeradmin,rangerlogger,rangerkms 0.0.0.0/0  md5' >> /var/lib/pgsql/data/pg_hba.conf
service postgresql reload"

    _info "No password required to login Ambari..."
    ssh -q root@$r_AMBARI_HOST "_f='/etc/ambari-server/conf/ambari.properties';grep -q '^api.authenticate=' \$_f && sed -i 's/^api.authenticate=true/api.authenticate=false/' \$_f || echo 'api.authenticate=false' >> \$_f;grep -q '^api.authenticated.user=' \$_f || echo 'api.authenticated.user=admin' >> \$_f; ambari-server restart --skip-database-check"

    _info "Creating 'admin' user in each node and in HDFS..."
    f_useradd_on_nodes "admin"
}

function f_ambari_agent_install() {
    local __doc__="Installing ambari-agent on all containers for manual registration"
    # ./start_hdp.sh -r ./node11-14_2.5.0.resp -f "f_ambari_agent_install 1 16"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    scp -q root@$r_AMBARI_HOST:/etc/yum.repos.d/ambari.repo /tmp/ambari.repo

    #local _cmd="yum install ambari-agent -y && grep "^hostname=$r_AMBARI_HOST"/etc/ambari-agent/conf/ambari-agent.ini || sed -i.bak "s@hostname=.+$@hostname=$r_AMBARI_HOST@1" /etc/ambari-agent/conf/ambari-agent.ini"
    local _cmd="which ambari-agent 2>/dev/null || yum install ambari-agent -y && ambari-agent reset $r_AMBARI_HOST"

    for i in `_docker_seq "$_how_many" "$_start_from"`; do
        scp -q /tmp/ambari.repo root@${_node}$i${r_DOMAIN_SUFFIX}:/etc/yum.repos.d/
        # Executing yum command one by one (not parallel)
        ssh -q -t root@${_node}$i${r_DOMAIN_SUFFIX} "$_cmd"
    done
}

function f_run_cmd_on_nodes() {
    local __doc__="Executing command on some containers"
    local _cmd="${1}"
    local _how_many="${2-$r_NUM_NODES}"
    local _start_from="${3-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    for i in `_docker_seq "$_how_many" "$_start_from"`; do
        ssh -q root@${_node}$i${r_DOMAIN_SUFFIX} -t "$_cmd"
    done
}

function f_run_cmd_all() {
    local __doc__="Executing command on all running containers"
    local _cmd="${1}"

    for _n in `docker ps --format "{{.Names}}"`; do
        # TODO: docker exec does not work
        ( set -x; ssh -q root@${_n}${r_DOMAIN_SUFFIX} -t "$_cmd" )
    done
}

function f_ambari_java_random() {
    local __doc__="Using urandom instead of random"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    local _javahome="`ssh -q root@$r_AMBARI_HOST "grep java.home /etc/ambari-server/conf/ambari.properties | cut -d \"=\" -f2"`"
    _info "Ambari Java Home ${_javahome}"
    local _cmd='grep -q "^securerandom.source=file:/dev/random" "'${_javahome%/}'/jre/lib/security/java.security" && sed -i.bak -e "s/^securerandom.source=file:\/dev\/random/securerandom.source=file:\/dev\/urandom/" "'${_javahome%/}'/jre/lib/security/java.security"'

    for i in `_docker_seq "$_how_many" "$_start_from"`; do
        ssh -q root@${_node}$i${r_DOMAIN_SUFFIX} -t "$_cmd"
    done

    # TODO: at this moment, trying to change only jre
    _cmd='_javahome="$(dirname $(dirname $(alternatives --display java | grep "link currently points to" | grep -oE "/.+jre.+/java$")))" && sed -i.bak -e "s/^securerandom.source=file:\/dev\/random/securerandom.source=file:\/dev\/urandom/" "$_javahome/lib/security/java.security"'

    for i in `_docker_seq "$_how_many" "$_start_from"`; do
        ssh -q root@${_node}$i${r_DOMAIN_SUFFIX} -t "$_cmd"
    done
}

function f_ambari_agent_fix_public_hostname() {
    local __doc__="Fixing public hostname (169.254.169.254 issue) by appending public_hostname.sh"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"
    local _cmd='grep "^public_hostname_script" /etc/ambari-agent/conf/ambari-agent.ini || ( echo -e "#!/bin/bash\necho \`hostname -f\`" > /var/lib/ambari-agent/public_hostname.sh && chmod a+x /var/lib/ambari-agent/public_hostname.sh && sed -i.bak "/run_as_user/i public_hostname_script=/var/lib/ambari-agent/public_hostname.sh\n" /etc/ambari-agent/conf/ambari-agent.ini )'

    for i in `_docker_seq "$_how_many" "$_start_from"`; do
        ssh -q root@${_node}$i${r_DOMAIN_SUFFIX} -t "$_cmd"
    done
}

function f_etcs_mount() {
    local __doc__="Mounting all agent's etc directories (handy for troubleshooting)"
    local _remount="$1"
    local _how_many="${2-$r_NUM_NODES}"
    local _start_from="${3-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"

    for i in `_docker_seq "$_how_many" "$_start_from"`; do
        if [ ! -d /mnt/etc/${_node}$i ]; then
            mkdir -p /mnt/etc/${_node}$i
        fi

        if _isNotEmptyDir "/mnt/etc/${_node}$i" ;then
            if ! _isYes "$_remount"; then
                continue
            else
                umount -f /mnt/etc/${_node}$i
            fi
        fi

        sshfs -o allow_other,uid=0,gid=0,umask=002,reconnect,follow_symlinks ${_node}${i}${r_DOMAIN_SUFFIX}:/etc /mnt/etc/${_node}${i}
    done
}

function f_local_repo() {
    local __doc__="TODO: Setup local repo on Docker host (Ubuntu)"
    local _local_dir="${1-/var/www/html/hdp}"
    local _document_root="${2-/var/www/html}"
    local _force_extract=""
    local _download_only=""

    if [ ! `which apt-get` ]; then
        _warn "No apt-get"
        return 1
    fi

    apt-get install -y apache2 createrepo

    if [ -z "$r_HDP_REPO_TARGZ" ]; then
        _error "Please specify HDP repo *tar.gz* file URL"
        return 1
    fi

    if [ -z "$_local_dir" ]; then
        if [ -z "$r_HDP_REPO_DIR" ]; then
            _warn "HDP local repository dirctory is not specified. Using /var/www/html/hdp"
            _local_dir="/var/www/html/hdp"
        else
            _local_dir="$r_HDP_REPO_DIR"
        fi
    fi

    if [ ! -d "$_local_dir" ]; then
        # Making directory for Apache2
        mkdir -p -m 777 $_local_dir
    fi

    cd "$_local_dir" || return 1

    local _tar_gz_file="`basename "$r_HDP_REPO_TARGZ"`"
    local _has_extracted=""
    local _hdp_dir="`find . -type d | grep -m1 -E "/${r_CONTAINER_OS}${r_REPO_OS_VER}/.+?/${r_HDP_REPO_VER}$"`"

    if _isNotEmptyDir "$_hdp_dir"; then
        if ! _isYes "$_force_extract"; then
            _has_extracted="Y"
        fi
        _info "$_hdp_dir already exists and not empty. Skipping download."
    elif [ -e "$_tar_gz_file" ]; then
        _info "$_tar_gz_file already exists. Skipping download."
    elif [ -e "${_local_dir%/}/$_tar_gz_file" ]; then
        _info "${_local_dir%/}/$_tar_gz_file already exists. Skipping download."
        _tar_gz_file="${_local_dir%/}/$_tar_gz_file"
    else
        if ! _isEnoughDisk "/$_local_dir" "10"; then
            _error "Not enough space to download $r_HDP_REPO_TARGZ"
            return 1
        fi

        #curl --limit-rate 200K --retry 20 -C - "$r_HDP_REPO_TARGZ" -o $_tar_gz_file
        wget -nv -c -t 20 --timeout=60 --waitretry=60 "$r_HDP_REPO_TARGZ"
    fi

    if _isYes "$_download_only"; then
        return $?
    fi

    if ! _isYes "$_has_extracted"; then
        tar xzvf "$_tar_gz_file"
        _hdp_dir="`find . -type d | grep -m1 -E "/${r_CONTAINER_OS}${r_REPO_OS_VER}/.+?/${r_HDP_REPO_VER}$"`"
        createrepo "$_hdp_dir" # --update
    fi

    local _util_tar_gz_file="`basename "$r_HDP_REPO_UTIL_TARGZ"`"
    local _util_has_extracted=""
    # TODO: not accurate
    local _hdp_util_dir="`find . -type d | grep -m1 -E "/HDP-UTILS-.+?/${r_CONTAINER_OS}${r_REPO_OS_VER}$"`"

    if _isNotEmptyDir "$_hdp_util_dir"; then
        if ! _isYes "$_force_extract"; then
            _util_has_extracted="Y"
        fi
        _info "$_hdp_util_dir already exists and not empty. Skipping download."
    elif [ -e "$_util_tar_gz_file" ]; then
        _info "$_util_tar_gz_file already exists. Skipping download."
    else
        wget -nv -c -t 20 --timeout=60 --waitretry=60 "$r_HDP_REPO_UTIL_TARGZ"
    fi

    if ! _isYes "$_util_has_extracted"; then
        tar xzvf "$_util_tar_gz_file"
        _hdp_util_dir="`find . -type d | grep -m1 -E "/HDP-UTILS-.+?/${r_CONTAINER_OS}${r_REPO_OS_VER}$"`"
        createrepo "$_hdp_util_dir"
    fi

    cd - &>/dev/null

    service apache2 start

    if [ -n "$r_DOCKER_PRIVATE_HOSTNAME" ]; then
        local _path_diff="${_local_dir#${_document_root}}"
        _path_diff="/${_path_diff#/}"
        local _repo_path="${_path_diff%/}${_hdp_dir#\.}"
        echo "### Local Repo URL: http://${r_DOCKER_PRIVATE_HOSTNAME}${r_DOMAIN_SUFFIX}${_repo_path}"
        local _util_repo_path="${_path_diff%/}${_hdp_util_dir#\.}"
        echo "### Local Repo URL: http://${r_DOCKER_PRIVATE_HOSTNAME}${r_DOMAIN_SUFFIX}${_util_repo_path}"

        # TODO: support only CentOS or RedHat at this moment
        if [ "${r_CONTAINER_OS}" = "centos" ] || [ "${r_CONTAINER_OS}" = "redhat" ]; then
            _port_wait "$r_AMBARI_HOST" "8080"

            f_ambari_set_repo "http://${r_DOCKER_PRIVATE_HOSTNAME}${r_DOMAIN_SUFFIX}${_repo_path}" "http://${r_DOCKER_PRIVATE_HOSTNAME}${r_DOMAIN_SUFFIX}${_util_repo_path}"
        else
            _warn "At this moment only centos or redhat for local repository"
        fi
    fi
}

function f_ambari_set_repo() {
    local __doc__="Update Ambari's repository URL information"
    local _repo_url="$1"
    local _util_url="$2"
    local _ambari_host="${3-$r_AMBARI_HOST}"

    _port_wait $_ambari_host 8080
    if [ $? -ne 0 ]; then
        _error "Ambari is not running on $_ambari_host 8080"
        return 1
    fi

    local _os_name="$r_CONTAINER_OS"
    if [ "${_os_name}" = "centos" ]; then
        _os_name="redhat"
    fi

    if _isUrl "$_repo_url"; then
        # TODO: admin:admin
        curl -H "X-Requested-By: ambari" -X PUT -u admin:admin "http://${r_AMBARI_HOST}:8080/api/v1/stacks/HDP/versions/${r_HDP_STACK_VERSION}/operating_systems/${_os_name}${r_REPO_OS_VER}/repositories/HDP-${r_HDP_STACK_VERSION}" -d '{"Repositories":{"base_url":"'${_repo_url}'","verify_base_url":true}}'
    fi

    if _isUrl "$_util_url"; then
        local _hdp_util_name="`echo $_util_url | grep -oP 'HDP-UTILS-[\d\.]+'`"
        curl -H "X-Requested-By: ambari" -X PUT -u admin:admin "http://${r_AMBARI_HOST}:8080/api/v1/stacks/HDP/versions/${r_HDP_STACK_VERSION}/operating_systems/${_os_name}${r_REPO_OS_VER}/repositories/${_hdp_util_name}" -d '{"Repositories":{"base_url":"'${_util_url}'","verify_base_url":true}}'
    fi
}

function f_repo_mount() {
    local __doc__="TODO: This would work on only my environment. Mounting VM host's directory to use for local repo"
    local _user="$1"
    local _host_pc="$2"
    local _src="${3-/Users/${_user}/Public/hdp/}"  # needs ending slash
    local _mounting_dir="${4-/var/www/html/hdp}" # no need ending slash

    if [ -z "$_host_pc" ]; then
        _host_pc="`env | awk '/SSH_CONNECTION/ {gsub("SSH_CONNECTION=", "", $1); print $1}'`"
        if [ -z "$_host_pc" ]; then
            _host_pc="`netstat -rn | awk '/^0\.0\.0\.0/ {print $2}'`"
        fi

        local _src="/Users/${_user}/Public/hdp/"
        _connect_str="${_user}@${_host_pc}:${_src}"
    fi

    if [ -z "${_user}" ]; then
        if [ -n "$SUDO_USER" ]; then
            _user="$SUDO_USER"
        else
            _user="$USER"
        fi
    fi

    mount | grep "$_mounting_dir"
    if [ $? -eq 0 ]; then
      umount -f "$_mounting_dir"
    fi
    if [ ! -d "$_mounting_dir" ]; then
        mkdir "$_mounting_dir" || return
    fi

    _info "Mounting ${_user}@${_host_pc}:${_src} to $_mounting_dir ..."
    _info "TODO: Edit this function for your env if above is not good (and Ctrl+c now)"
    sleep 4
    sshfs -o allow_other,uid=0,gid=0,umask=002,reconnect,follow_symlinks ${_user}@${_host_pc}:${_src} "${_mounting_dir%/}"
}

function f_services_start() {
    local __doc__="Request 'Start all' to Ambari via API"
    local _c="`f_get_cluster_name $r_AMBARI_HOST`" || return 1
    _info "Will start all services ..."
    if [ -z "$_c" ]; then
      _error "No cluster name (check PostgreSQL)..."
      return 1
    fi

    _port_wait "$r_AMBARI_HOST" "8080"
    _ambari_agent_wait

    curl -u admin:admin -H "X-Requested-By:ambari" "http://$r_AMBARI_HOST:8080/api/v1/clusters/${_c}/services?" -X PUT --data '{"RequestInfo":{"context":"_PARSE_.START.ALL_SERVICES","operation_level":{"level":"CLUSTER","cluster_name":"'${_c}'"}},"Body":{"ServiceInfo":{"state":"STARTED"}}}'
    echo ""
}

function f_service() {
    local __doc__="Request STOP/START/RESTART to Ambari via API with maintenance mode (for _s in hbase kafka atlas; do  f_service \$_s stop; done)"
    local _service="$1"
    local _action="$2"
    local _ambari_host="${3-$r_AMBARI_HOST}"
    local _maintenance_mode="OFF"
    local _c="`f_get_cluster_name $_ambari_host`" || return 1

    if [ -z "$_c" ]; then
      _error "No cluster name (check PostgreSQL)..."
      return 1
    fi

    if [ -z "$_service" ]; then
        _info "Available Services"
        _ambari_query_sql "select service_name from servicedesiredstate where 1=1 order by service_name" "$_ambari_host"
        return
    fi

    if [ -z "$_action" ]; then
        _info "Acceptable actions: start, stop, restart" # Actually it accespts others like DELETE...
        return
    fi

    _service="${_service^^}"
    _action="${_action^^}"

    if [ "$_action" = "RESTART" ]; then
        f_service "$_service" "stop" "$_ambari_host" || return $?
        for _i in {1..9}; do
            _n="`_ambari_query_sql "select count(*) from request where request_context ='set INSTALLED for $_service by f_service' and end_time < start_time"`"
            [ 0 -eq $_n ] && break;
            sleep 10
        done
        f_service "$_service" "start" "$_ambari_host"
        return
    fi

    [ "$_action" = "START" ] && _action="STARTED"
    [ "$_action" = "STOP" ] && _action="INSTALLED"
    [ "$_action" = "INSTALLED" ] && _maintenance_mode="ON"

    _n="`_ambari_query_sql "select count(*) from request where request_context ='set $_action for $_service by f_service' and end_time < start_time"`"
    [ 0 -lt $_n ] && return;

    curl -u admin:admin -H "X-Requested-By:ambari" -X PUT -d '{"RequestInfo":{"context":"Maintenance Mode '$_maintenance_mode' '$_service'"},"Body":{"ServiceInfo":{"maintenance_state":"'$_maintenance_mode'"}}}' "http://$_ambari_host:8080/api/v1/clusters/$_c/services/$_service"
    local _request_context=""
    curl -u admin:admin -H "X-Requested-By:ambari" -X PUT -d '{"RequestInfo":{"context":"set '$_action' for '$_service' by f_service","operation_level":{"level":"SERVICE","cluster_name":"'$_c'","service_name":"'$_service'"}},"Body":{"ServiceInfo":{"state":"'$_action'"}}}' "http://$_ambari_host:8080/api/v1/clusters/$_c/services/$_service"
    echo ""
}

function _ambari_agent_wait() {
    local _db_host="${1-$r_AMBARI_HOST}"
    local _how_many="${2-$r_NUM_NODES}"
    local _u=""

    if [ -z "$_how_many" ] || [ $_how_many -lt 1 ]; then
        _error "No node number for validate is specified."
        return 2
    fi

    for i in `seq 1 10`; do
        _u=$(_ambari_query_sql "select case when (select count(*) from hoststate)=0 then -1 ELSE (select count(*) from hoststate where health_status ilike '%HEALTHY%') end;" "$_db_host")
        #curl -s --head "http://$r_AMBARI_HOST:8080/" | grep '200 OK'
        if [ $_how_many -le $_u ]; then
            return 0
        elif [ -1 -eq $_u ]; then
            _warn "No agent has been installed"
            return 100
        fi

        _info "Some Ambari Agent is not in HEALTHY state ($_u / $_how_many). waiting..."
        sleep 4
    done
    return 1
}

function f_screen_cmd() {
    local __doc__="Output GNU screen command"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"
    screen -ls | grep -w "docker_$r_CLUSTER_NAME"
    if [ $? -ne 0 ]; then
      _info "You may want to run the following commands to start GNU Screen:"
      echo "screen -S \"docker_$r_CLUSTER_NAME\" bash -c 'for s in \``_docker_seq "$r_NUM_NODES" "$r_NODE_START_NUM" "Y"`\`; do screen -t \"${_node}\${s}\" \"ssh\" \"${_node}\${s}${r_DOMAIN_SUFFIX}\"; sleep 1; done'"
    fi
}

function f_vmware_tools_install() {
    local __doc__="Install VMWare Tools in Ubuntu host"
    mkdir /media/cdrom; mount /dev/cdrom /media/cdrom && cd /media/cdrom && cp VMwareTools-*.tar.gz /tmp/ && cd /tmp/ && tar xzvf VMwareTools-*.tar.gz && cd vmware-tools-distrib/ && ./vmware-install.pl -d
}

function f_sysstat_setup() {
    local __doc__="Install and set up sysstat"

    if [ ! `which apt-get` ]; then
        _warn "No apt-get"
        return 1
    fi

    which sar &>/dev/null
    if [ $? -ne 0 ]; then
        apt-get -y install sysstat
    fi
    grep -i '^ENABLED="false"' /etc/default/sysstat &>/dev/null
    if [ $? -eq 0 ]; then
        sed -i.bak -e 's/ENABLED=\"false\"/ENABLED=\"true\"/' /etc/default/sysstat
        service sysstat restart
    fi
}

function p_host_setup() {
    local __doc__="Install packages into this host (Ubuntu)"
    _log "INFO" "Starting Host setup | logfile = " "/tmp/p_host_setup.log"

    if [ `which apt-get` ]; then
        _log "INFO" "Starting apt-get update"
        _isYes "$g_APT_UPDATE_DONE" || apt-get update &>> /tmp/p_host_setup.log && g_APT_UPDATE_DONE="Y"

        if _isYes "$r_APTGET_UPGRADE"; then
            _log "INFO" "Starting apt-get upgrade"
            apt-get upgrade -y &>> /tmp/p_host_setup.log
        fi

        # NOTE: psql (postgresql-client) is required
        _log "INFO" "Starting apt-get install packages"
        apt-get -y install ntpdate curl wget sshfs sysv-rc-conf tcpdump sharutils unzip postgresql-client libxml2-utils expect netcat nscd &>> /tmp/p_host_setup.log
        #mailutils postfix mysql-client htop

        _log "INFO" "Starting f_docker_setup"
        f_docker_setup &>> /tmp/p_host_setup.log
        #f_sysstat_setup &>> /tmp/p_host_setup.log
        _log "INFO" "Starting f_host_performance"
        f_host_performance &>> /tmp/p_host_setup.log
        _log "INFO" "Starting f_host_misc"
        f_host_misc &>> /tmp/p_host_setup.log
        _log "INFO" "Starting f_dnsmasq"
        f_dnsmasq &>> /tmp/p_host_setup.log
    fi

    _log "INFO" "Starting f_docker0_setup"
    f_docker0_setup &>> /tmp/p_host_setup.log
    _log "INFO" "Starting f_dockerfile"
    f_dockerfile &>> /tmp/p_host_setup.log
    _log "INFO" "Starting f_docker_base_create"
    f_docker_base_create &>> /tmp/p_host_setup.log
    _log "INFO" "Starting f_docker_run"
    f_docker_run &>> /tmp/p_host_setup.log
    _log "INFO" "Starting f_docker_start"
    f_docker_start &>> /tmp/p_host_setup.log

    if _isYes "$r_PROXY"; then
        _log "INFO" "Starting f_apache_proxy"
        f_apache_proxy &>> /tmp/p_host_setup.log
        _log "INFO" "Starting f_yum_remote_proxy"
        f_yum_remote_proxy &>> /tmp/p_host_setup.log
    fi

    if ! _isYes "$r_AMBARI_NOT_INSTALL"; then
        _log "INFO" "Starting f_ambari_server_install"
        f_ambari_server_install &>> /tmp/p_host_setup.log
        _log "INFO" "Starting f_ambari_server_start"
        f_ambari_server_start &>> /tmp/p_host_setup.log

        _port_wait "$r_AMBARI_HOST" "8080" &>> /tmp/p_host_setup.log
        if [ $? -eq 0 ]; then
            _log "INFO" "Starting f_run_cmd_on_nodes chpasswd"
            f_run_cmd_on_nodes "chpasswd <<< root:$g_DEFAULT_PASSWORD" &>> /tmp/p_host_setup.log
            _log "INFO" "Starting f_run_cmd_on_nodes ambari-agent start"
            f_run_cmd_on_nodes "ambari-agent start" &>> /tmp/p_host_setup.log
            _ambari_agent_wait &>> /tmp/p_host_setup.log
            if [ $? -ne 0 ]; then
                _log "INFO" "Starting f_ambari_agent_install"
                f_ambari_agent_install &>> /tmp/p_host_setup.log
                _log "INFO" "Starting f_ambari_agent_fix_public_hostname"
                f_ambari_agent_fix_public_hostname &>> /tmp/p_host_setup.log
                _log "INFO" "Starting f_run_cmd_on_nodes ambari-agent start"
                f_run_cmd_on_nodes "ambari-agent start" &>> /tmp/p_host_setup.log
               _ambari_agent_wait &>> /tmp/p_host_setup.log
            fi
        else
            _log "WARN" "Ambari Server may not be running but keep continuing..."
        fi

        if _isYes "$r_HDP_LOCAL_REPO"; then
            _log "INFO" "Starting f_local_repo"
            f_local_repo &>> /tmp/p_host_setup.log
        elif [ -n "$r_HDP_REPO_URL" ]; then
            # TODO: at this moment r_HDP_UTIL_URL always empty if not local repo
            _log "INFO" "Starting f_ambari_set_repo"
            f_ambari_set_repo "$r_HDP_REPO_URL" "$r_HDP_UTIL_URL" &>> /tmp/p_host_setup.log
        fi

        if _isYes "$r_AMBARI_BLUEPRINT"; then
            _log "INFO" "Starting p_ambari_blueprint"
            p_ambari_blueprint &>> /tmp/p_host_setup.log
        fi

        f_port_forward 8080 $r_AMBARI_HOST 8080 "Y" &>> /tmp/p_host_setup.log
    fi

    f_port_forward_ssh_on_nodes
    _log "INFO" "Completed. Please run f_ambari_update_config once when HDFS is running."

    f_screen_cmd
}

function f_dnsmasq() {
    local __doc__="Install and set up dnsmasq"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _dns="${r_DNS_SERVER-$g_DNS_SERVER}"
    
    if [ ! `ssh $_dns which apt-get` ]; then
        _warn "No apt-get or ssh to $_dns not allowed"
        return 1
    fi
    ssh -q $_dns apt-get -y install dnsmasq

    ssh -q $_dns "grep '^addn-hosts=' /etc/dnsmasq.conf || echo 'addn-hosts=/etc/banner_add_hosts' >> /etc/dnsmasq.conf"

    f_dnsmasq_banner_reset "$_how_many" "$_start_from"
}

function f_dnsmasq_banner_reset() {
    local __doc__="Regenerate /etc/banner_add_hosts"
    local _how_many="${1-$r_NUM_NODES}"
    local _start_from="${2-$r_NODE_START_NUM}"
    local _node="${r_NODE_HOSTNAME_PREFIX-$g_NODE_HOSTNAME_PREFIX}"
    local _dns="${r_DNS_SERVER-$g_DNS_SERVER}"

    local _docker0="`f_docker_ip`"
    # TODO: the first IP can be wrong one
    if [ -n "$r_DOCKER_HOST_IP" ]; then
        _docker0="$r_DOCKER_HOST_IP"
    fi

    if [ -z "$r_DOCKER_PRIVATE_HOSTNAME" ]; then
        _warn "Hostname for docker host in the private network is empty. using dockerhost1"
        r_DOCKER_PRIVATE_HOSTNAME="dockerhost1"
    fi

    rm -rf /tmp/banner_add_hosts

    scp -q $_dns:/etc/banner_add_hosts /tmp/banner_add_hosts
    if [ ! -s /tmp/banner_add_hosts ]; then
        echo "$_docker0     ${r_DOCKER_PRIVATE_HOSTNAME}${r_DOMAIN_SUFFIX} ${r_DOCKER_PRIVATE_HOSTNAME}" > /tmp/banner_add_hosts
    else
        grep -vE "$_docker0|${r_DOCKER_PRIVATE_HOSTNAME}${r_DOMAIN_SUFFIX}" /tmp/banner_add_hosts > /tmp/banner
        echo "$_docker0     ${r_DOCKER_PRIVATE_HOSTNAME}${r_DOMAIN_SUFFIX} ${r_DOCKER_PRIVATE_HOSTNAME}" >> /tmp/banner
	
        cat /tmp/banner > /tmp/banner_add_hosts
    fi

    for _n in `_docker_seq "$_how_many" "$_start_from"`; do
        grep -vE "${_node}${_n}${r_DOMAIN_SUFFIX}|${r_DOCKER_NETWORK_ADDR}${_n}" /tmp/banner_add_hosts > /tmp/banner
        echo "${r_DOCKER_NETWORK_ADDR}${_n}    ${_node}${_n}${r_DOMAIN_SUFFIX} ${_node}${_n}" >> /tmp/banner
        cat /tmp/banner > /tmp/banner_add_hosts
    done

    scp -q /tmp/banner_add_hosts $_dns:/etc/

    ssh -q $_dns service dnsmasq restart
}

function f_host_performance() {
    local __doc__="Performance related changes on the host. Eg: Change kernel parameters on Docker Host (Ubuntu)"
    grep -q '^vm.swappiness' /etc/sysctl.conf || echo "vm.swappiness = 0" >> /etc/sysctl.conf
    sysctl -w vm.swappiness=0

    grep -q '^net.core.somaxconn' /etc/sysctl.conf || echo "net.core.somaxconn = 16384" >> /etc/sysctl.conf
    sysctl -w net.core.somaxconn=16384

    # also ip forwarding as well
    grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1

    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag

    grep -q '^echo never > /sys/kernel/mm/transparent_hugepage/enabled' /etc/rc.local
    if [ $? -ne 0 ]; then
        sed -i.bak '/^exit 0/i echo never > /sys/kernel/mm/transparent_hugepage/enabled\necho never > /sys/kernel/mm/transparent_hugepage/defrag\n' /etc/rc.local
    fi
}

function f_host_misc() {
    local __doc__="Misc. changes for Ubuntu OS"
    grep "^IP=" /etc/rc.local &>/dev/null
    if [ $? -ne 0 ]; then
        sed -i.bak '/^exit 0/i IP=$(/sbin/ifconfig eth0 | grep -oP "inet addr:\\\d+\\\.\\\d+\\\.\\\d+\\\.\\\d+" | cut -d":" -f2); echo "eth0 IP: $IP" > /etc/issue\n' /etc/rc.local
    fi

    # AWS / Openstack only change
    if [ -s /home/ubuntu/.ssh/authorized_keys ] && [ ! -f $HOME/.ssh/authorized_keys.bak ]; then
        cp -p $HOME/.ssh/authorized_keys $HOME/.ssh/authorized_keys.bak
        grep 'Please login as the user' $HOME/.ssh/authorized_keys && cat /home/ubuntu/.ssh/authorized_keys > $HOME/.ssh/authorized_keys
    fi

    grep '^PasswordAuthentication no' /etc/ssh/sshd_config && sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config || return $?
    grep '^PermitRootLogin without-password' /etc/ssh/sshd_config && sed -i 's/^PermitRootLogin without-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    if [ $? -eq 0 ]; then
        service ssh restart
    fi
}

function f_dockerfile() {
    local __doc__="Download dockerfile and replace private key"
    local _url="$1"
    if [ -z "$_url" ]; then
        _url="$r_DOCKERFILE_URL"
    fi
    if [ -z "$_url" ]; then
        _error "No DockerFile URL/path"
        return 1
    fi

    if _isUrl "$_url"; then
        if [ -e ./DockerFile ]; then
            # only one backup would be enough
            mv -f ./DockerFile ./DockerFile.bak
        fi

        _info "Downloading $_url ..."
        wget -nv "$_url" -O ./DockerFile
    fi

    f_ssh_setup

    local _pkey="`sed ':a;N;$!ba;s/\n/\\\\\\\n/g' $HOME/.ssh/id_rsa`"

    sed -i "s@_REPLACE_WITH_YOUR_PRIVATE_KEY_@${_pkey}@1" ./DockerFile
}

function f_ssh_setup() {
    if [ ! -e $HOME/.ssh/id_rsa ]; then
        ssh-keygen -f $HOME/.ssh/id_rsa -q -N ""
    fi

    if [ ! -e $HOME/.ssh/id_rsa.pub ]; then
        ssh-keygen -y -f $HOME/.ssh/id_rsa > $HOME/.ssh/id_rsa.pub
    fi

    _key="`cat $HOME/.ssh/id_rsa.pub | awk '{print $2}'`"
    grep "$_key" $HOME/.ssh/authorized_keys &>/dev/null
    if [ $? -ne 0 ] ; then
      cat $HOME/.ssh/id_rsa.pub >> $HOME/.ssh/authorized_keys && chmod 600 $HOME/.ssh/authorized_keys
    fi

    if [ ! -e $HOME/.ssh/config ]; then
        echo "Host *
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null" > $HOME/.ssh/config
    fi

    # TODO: At this moment the following lines are not used
    if [ ! -e /root/.ssh/id_rsa ]; then
        mkdir /root/.ssh &>/dev/null
        cp $HOME/.ssh/id_rsa /root/.ssh/id_rsa
        chmod 600 /root/.ssh/id_rsa
        chown -R root:root /root/.ssh
    fi
}

function f_hostname_set() {
    local __doc__="Set hostname"
    local _new_name="$1"
    if [ -z "$_new_name" ]; then
      _error "no hostname"
      return 1
    fi

    local _current="`cat /etc/hostname`"
    hostname $_new_name
    echo "$_new_name" > /etc/hostname
    sed -i.bak "s/\b${_current}\b/${_new_name}/g" /etc/hosts
    diff /etc/hosts.bak /etc/hosts
}

function f_apache_proxy() {
    local _proxy_dir="/var/www/proxy"
    local _cache_dir="/var/cache/apache2/mod_cache_disk"
    local _port="${r_PROXY_PORT-28080}"

    if [ ! `which apt-get` ]; then
        _warn "No apt-get"
        return 1
    fi

    mkdir -m 777 $_proxy_dir
    mkdir -p -m 777 ${_cache_dir}

    if [ -s /etc/apache2/sites-available/proxy.conf ]; then
        _warn "/etc/apache2/sites-available/proxy.conf already exists. Skipping..."
        return 0
    fi

    apt-get install -y apache2 apache2-utils
    a2enmod proxy proxy_http proxy_connect cache cache_disk

    grep -i "^Listen ${_port}" /etc/apache2/ports.conf || echo "Listen ${_port}" >> /etc/apache2/ports.conf

    echo "<VirtualHost *:${_port}>
    DocumentRoot ${_proxy_dir}
    LogLevel warn
    ErrorLog \${APACHE_LOG_DIR}/proxy_error.log
    CustomLog \${APACHE_LOG_DIR}/proxy_access.log combined

    <IfModule mod_proxy.c>

        ProxyRequests On
        <Proxy *>
            AddDefaultCharset off
            Order deny,allow
            Allow from all
        </Proxy>

        ProxyVia On

        <IfModule mod_cache_disk.c>
            CacheRoot ${_cache_dir}
            CacheIgnoreCacheControl On
            CacheEnable disk /
            CacheEnable disk http://
            CacheDirLevels 2
            CacheDirLength 1
            CacheMaxFileSize 50000000
        </IfModule>

    </IfModule>
</VirtualHost>" > /etc/apache2/sites-available/proxy.conf

    a2ensite proxy
    # TODO: should use restart?
    service apache2 reload
}

function f_yum_remote_proxy() {
    local __doc__="This function edits yum.conf of each running container to set up proxy (http://your.proxy.server:port)"
    local _proxy_url="$1"
    local _port="${r_PROXY_PORT-28080}"

    if [ -z "$_proxy_url" ]; then
        if [ -z "$r_DOCKER_HOST_IP" ]; then
            _error "No proxy (http://your.proxy.server:port) to set"
            return 1
        else
            _info "No proxy, so that using http://${r_DOCKER_HOST_IP}:${_port}"
            _proxy_url="http://${r_DOCKER_HOST_IP}:${_port}"
        fi
    fi

    # set up proxy for all running containers
    for _host in `docker ps --format "{{.Names}}"`; do
        ssh -q root@$_host "grep ^proxy /etc/yum.conf || echo \"proxy=${_proxy_url}\" >> /etc/yum.conf"
    done
}

function f_gw_set() {
    local __doc__="Set new default gateway to each container"
    local _gw="`f_docker_ip`"
    # NOTE: Assuming docker name and hostname is same
    for _name in `docker ps --format "{{.Names}}"`; do
        ssh -q root@${_name}${r_DOMAIN_SUFFIX} "route add default gw $_gw eth0"
    done
}

function f_docker_ip() {
    local __doc__="Output docker0 IP or specified NIC's IP"
    local _ip="${1}"
    local _if="${2-docker0}"
    local _ifconfig="`ifconfig $_if 2>/dev/null`"

    if [ -z "$_ifconfig" ]; then
        if [ -n "$_ip" ]; then
            echo "$_ip"
            return 0
        fi
        return $?
    fi

    echo "$_ifconfig" | grep -oP 'inet addr:\d+\.\d+\.\d+\.\d+' | cut -d":" -f2
    return $?
}

function f_log_cleanup() {
    local __doc__="Deleting log files which group owner is hadoop"
    local _days="${1-7}"
    _warn "Deleting hadoop logs which is older than $_days days..."
    sleep 5
    # NOTE: Assuming docker name and hostname is same
    for _name in `docker ps --format "{{.Names}}"`; do
        ssh -q root@${_name}${r_DOMAIN_SUFFIX} 'find /var/log/ -type f -group hadoop \( -name "*\.log*" -o -name "*\.out*" \) -mtime +'${_days}' -exec grep -Iq . {} \; -and -print0 | xargs -0 -t -n1 -I {} rm -f {};find /var/log/ambari-* -type f \( -name "*\.log*" -o -name "*\.out*" \) -mtime +'${_days}' -exec grep -Iq . {} \; -and -print0 | xargs -0 -t -n1 -I {} rm -f {}' &
    done
    wait
}

function f_update_check() {
    local __doc__="Check if newer script is available, then download."
    local _local_file_path="${1-$BASH_SOURCE}"
    local _file_name=`basename ${_local_file_path}`
    local _remote_url="https://raw.githubusercontent.com/hajimeo/samples/master/bash/$_file_name"   # TODO: shouldn't I hard-code?

    if _isYes "$_SKIP_UPDATE_CHECK" ; then
        return
    fi

    if [ ! -s "$_local_file_path" ]; then
        _warn "$FUNCNAME: $_local_file_path does not exist or empty"
        return 1
    fi

    if ! _isCmd "curl"; then
        if [ "$0" = "$BASH_SOURCE" ]; then
            _warn "$FUNCNAME: No 'curl' command. Exiting."; return 1
        else
            if [ `which apt-get` ]; then
                _ask "Would you like to install 'curl'?" "Y"
                if ! _isYes ; then
                    return 1
                fi
                DEBIAN_FRONTEND=noninteractive apt-get -y install curl &>/dev/null
            fi
        fi
    fi

    # --basic --user ${r_svn_user}:${r_svn_pass}      last-modified    cut -c16-
    local _remote_length=`curl -m 4 -s -k -L --head "${_remote_url}" | grep -i '^Content-Length:' | awk '{print $2}' | tr -d '\r'`
    if [ -z "$_remote_length" ]; then _warn "$FUNCNAME: Unknown remote length."; return 1; fi

    #local _local_last_mod_ts=`stat -c%Y ${_local_file_path}`
    _local_last_length=`wc -c ./start_hdp.sh | awk '{print $1}'`

    if [ ${_remote_length} -ne ${_local_last_length} ]; then
        _info "Different file is available (r=$_remote_length/l=$_local_last_length)"
        _ask "Would you like to download?" "Y"
        if ! _isYes; then return 0; fi
        if [ ${_remote_length} -lt ${_local_last_length} ]; then
            _ask "Are you sure?" "N"
            if ! _isYes; then return 0; fi
        fi

        _backup "${_local_file_path}"

        curl -k -L "$_remote_url" -o ${_local_file_path} || _critical "$FUNCNAME: Update failed."

        #_info "Validating the downloaded script..."
        #source ${_local_file_path} || _critical "Please contact the script author."
        _info "Script has been updated. Please re-run."
        _exit 0
    fi
}

function f_vnc_setup() {
    local __doc__="Install X and VNC Server. NOTE: this uses about 400MB space"
    local _user="${1-$USER}"
    local _vpass="${2-$g_DEFAULT_PASSWORD}"
    local _pass="${3-$g_DEFAULT_PASSWORD}"

    if [ ! `which apt-get` ]; then
        _warn "No apt-get"
        return 1
    fi

    if [ ! `grep "$_user" /etc/passwd` ]; then
        f_useradd "$_user" "$_pass" || return $?
    fi

    apt-get install -y xfce4 xfce4-goodies firefox tightvncserver autocutsel

    su - $_user -c 'mkdir ${HOME%/}/.vnc; echo "'$_vpass'" | vncpasswd -f > ${HOME%/}/.vnc/passwd
chmod 600 ${HOME%/}/.vnc/passwd
mv ${HOME%/}/.vnc/xstartup ${HOME%/}/.vnc/xstartup.bak &>/dev/null
echo "#!/bin/bash
xrdb ${HOME%/}/.Xresources
autocutsel -fork
startxfce4 &" > ${HOME%/}/.vnc/xstartup
chmod u+x ${HOME%/}/.vnc/xstartup'

    echo "To start:"
    echo "su - $_user -c 'vncserver -geometry 1280x768 -depth 16 :1'"
    echo "To stop:"
    echo "su - $_user -c 'vncserver -kill :1'"

    # to check
    #sudo netstat -aopen | grep 5901
}

function f_x2go_setup() {
    local __doc__="Install and setup next generation remote desktop X2Go"
    local _user="${1-$USER}"
    local _pass="${2-$g_DEFAULT_PASSWORD}"

    if [ ! `which apt-get` ]; then
        _warn "No apt-get"
        return 1
    fi

    apt-add-repository ppa:x2go/stable -y
    apt-get update
    apt-get install xfce4 xfce4-goodies firefox x2goserver x2goserver-xsession -y || return $?

    _info "Please install X2Go client from http://wiki.x2go.org/doku.php/doc:installation:x2goclient"

    if [ ! `grep "$_user" /etc/passwd` ]; then
        f_useradd "$_user" "$_pass" || return $?
    fi
}

function f_nifidemo_add() {
    local __doc__="Deprecated: Add Nifi in HDP"
    local _stack_version="${1-$r_HDP_STACK_VERSION}"
    # https://github.com/abajwa-hw/ambari-nifi-service

    #rm -rf /var/lib/ambari-server/resources/stacks/HDP/'$_stack_version'/services/NIFI
    #TODO: curl http://public-repo-1.hortonworks.com/HDF/centos6/2.x/updates/2.1.2.0/tars/hdf_ambari_mp/hdf-ambari-mpack-2.1.2.0-10.tar.gz -O
    # http://public-repo-1.hortonworks.com/HDF/2.1.2.0/nifi-1.1.0.2.1.2.0-10-bin.tar.gz
    ssh -q root@$r_AMBARI_HOST 'yum install git -y
git clone https://github.com/abajwa-hw/ambari-nifi-service.git /var/lib/ambari-server/resources/stacks/HDP/'$_stack_version'/services/NIFI && service ambari-server restart'
}

function f_useradd() {
    local __doc__="Add user on Host"
    local _user="$1"
    local _pwd="$2"

    # should specify home directory just in case?
    useradd -d "/home/$_user/" -s `which bash` -p $(echo "$_pwd" | openssl passwd -1 -stdin) "$_user"
    mkdir "/home/$_user/" && chown "$_user":"$_user" "/home/$_user/"

    if [ -f ${HOME%/}/.ssh/id_rsa ] && [ -d "/home/$_user/" ]; then
        mkdir "/home/$_user/.ssh" && chown "$_user":"$_user" "/home/$_user/.ssh"
        cp ${HOME%/}/.ssh/id_rsa* "/home/$_user/.ssh/"
        chown "$_user":"$_user" /home/$_user/.ssh/id_rsa*
        chmod 600 "/home/$_user/.ssh/id_rsa"
    fi
}

function f_useradd_on_nodes() {
    local __doc__="Add user in multiple nodes. NOTE: expecting host has KDC"
    local _user="$1"
    local _password="${2-$r_DEFAULT_PASSWORD}"
    local _how_many="${3-$r_NUM_NODES}"
    local _start_from="${4-$r_NODE_START_NUM}"
    local _hdfs_client_node="$5"
    local _c="`f_get_cluster_name`"

    f_run_cmd_on_nodes 'useradd '$_user' -s `which bash` -p $(echo "'$_password'" | openssl passwd -1 -stdin) && usermod -a -G users '$_user $_how_many $_start_from

    if [ -z "$_hdfs_client_node" ]; then
        _hdfs_client_node="`_ambari_query_sql "select h.host_name from hostcomponentstate hcs join hosts h on hcs.host_id=h.host_id where component_name='HDFS_CLIENT' and current_state='INSTALLED' limit 1" $r_AMBARI_HOST`"
    fi
    ssh -q root@$_hdfs_client_node -t "sudo -u hdfs bash -c \"kinit -kt /etc/security/keytabs/hdfs.headless.keytab hdfs-${_c}; hdfs dfs -mkdir /user/$_user && hdfs dfs -chown $_user:hadoop /user/$_user\""

    if which kadmin.local; then
        if [ -z "$_password" ]; then
            if [ -e "${_user}.headless.keytab" ]; then
                mv -f "${_user}.headless.keytab" "${_user}.headless.keytab.bak"
            fi
            kadmin.local -q "add_principal -randkey $_user" && kadmin.local -q "xst -k ${_user}.headless.keytab ${_user}" && _info "Generated ${_user}.headless.keytab"
        else
            kadmin.local -q "add_principal -pw $_password $_user"
        fi
    fi
}

### Utility type functions #################################################
_YES_REGEX='^(1|y|yes|true|t)$'
_IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
_IP_RANGE_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(/[0-3]?[0-9])?$'
_HOSTNAME_REGEX='^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$'
_URL_REGEX='(https?|ftp|file|svn)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'
_TEST_REGEX='^\[.+\]$'

function _ask() {
    local _question="$1"
    local _default="$2"
    local _var_name="$3"
    local _is_secret="$4"
    local _is_mandatory="$5"
    local _validation_func="$6"

    local _default_orig="$_default"
    local _cmd=""
    local _full_question="${_question}"
    local _trimmed_answer=""
    local _previous_answer=""

    if [ -z "${_var_name}" ]; then
        __LAST_ANSWER=""
        _var_name="__LAST_ANSWER"
    fi

    # currently only checking previous value of the variable name starting with "r_"
    if [[ "${_var_name}" =~ ^r_ ]]; then
        _previous_answer=`_trim "${!_var_name}"`
        if [ -n "${_previous_answer}" ]; then _default="${_previous_answer}"; fi
    fi

    if [ -n "${_default}" ]; then
        if _isYes "$_is_secret" ; then
            _full_question="${_question} [*******]"
        else
            _full_question="${_question} [${_default}]"
        fi
    fi

    if _isYes "$_is_secret" ; then
        local _temp_secret=""

        while true ; do
            read -p "${_full_question}: " -s "${_var_name}"; echo ""

            if [ -z "${!_var_name}" -a -n "${_default}" ]; then
                eval "${_var_name}=\"${_default}\""
                break;
            else
                read -p "${_question} (again): " -s "_temp_secret"; echo ""

                if [ "${!_var_name}" = "${_temp_secret}" ]; then
                    break;
                else
                    echo "1st value and 2nd value do not match."
                fi
            fi
        done
    else
        read -p "${_full_question}: " "${_var_name}"

        _trimmed_answer=`_trim "${!_var_name}"`

        if [ -z "${_trimmed_answer}" -a -n "${_default}" ]; then
            # if new value was only space, use original default value instead of previous value
            if [ -n "${!_var_name}" ]; then
                eval "${_var_name}=\"${_default_orig}\""
            else
                eval "${_var_name}=\"${_default}\""
            fi
        else
            eval "${_var_name}=\"${_trimmed_answer}\""
        fi
    fi

    # if empty value, check if this is a mandatory field.
    if [ -z "${!_var_name}" ]; then
        if _isYes "$_is_mandatory" ; then
            echo "'${_var_name}' is a mandatory parameter."
            _ask "$@"
        fi
    else
        # if not empty and if a validation function is given, use function to check it.
        if _isValidateFunc "$_validation_func" ; then
            $_validation_func "${!_var_name}"
            if [ $? -ne 0 ]; then
                _ask "Given value does not look like correct. Would you like to re-type?" "Y"
                if _isYes; then
                    _ask "$@"
                fi
            fi
        fi
    fi
}
function _backup() {
    local __doc__="Backup the given file path into ${g_BACKUP_DIR}."
    local _file_path="$1"
    local _force="$2"
    local _file_name="`basename $_file_path`"
    local _new_file_name=""

    if [ ! -e "$_file_path" ]; then
        _warn "$FUNCNAME: Not taking a backup as $_file_path does not exist."
        return 1
    fi

    local _mod_dt="`stat -c%y $_file_path`"
    local _mod_ts=`date -d "${_mod_dt}" +"%Y%m%d-%H%M%S"`

    _new_file_name="${_file_name}_${_mod_ts}"
    if ! _isYes "$_force"; then
        if [ -e "${g_backup_dir%/}/${_new_file_name}" ]; then
            _info "$_file_name has been already backed up. Skipping..."
            return 0
        fi
    fi

    _makeBackupDir
    cp -p ${_file_path} ${g_backup_dir%/}/${_new_file_name} || _critical "$FUNCNAME: failed to backup ${_file_path}"
}
function _makeBackupDir() {
    if [ ! -d "${g_BACKUP_DIR}" ]; then
        mkdir -p -m 700 "${g_BACKUP_DIR}"
        #[ -n "$SUDO_USER" ] && chown $SUDO_UID:$SUDO_GID ${g_BACKUP_DIR}
    fi
}
function _isEnoughDisk() {
    local __doc__="Check if entire system or the given path has enough space with GB."
    local _dir_path="${1-/}"
    local _required_gb="$2"
    local _available_space_gb=""

    _available_space_gb=`_freeSpaceGB "${_dir_path}"`

    if [ -z "$_required_gb" ]; then
        echo "${_available_space_gb}GB free space"
        _required_gb=`_totalSpaceGB`
        _required_gb="`expr $_required_gb / 10`"
    fi

    if [ $_available_space_gb -lt $_required_gb ]; then return 1; fi
    return 0
}
function _freeSpaceGB() {
    local __doc__="Output how much space for given directory path."
    local _dir_path="$1"
    if [ ! -d "$_dir_path" ]; then _dir_path="-l"; fi
    df -P --total ${_dir_path} | grep -i ^total | awk '{gb=sprintf("%.0f",$4/1024/1024);print gb}'
}
function _totalSpaceGB() {
    local __doc__="Output how much space for given directory path."
    local _dir_path="$1"
    if [ ! -d "$_dir_path" ]; then _dir_path="-l"; fi
    df -P --total ${_dir_path} | grep -i ^total | awk '{gb=sprintf("%.0f",$2/1024/1024);print gb}'
}
function _port_wait() {
    local _host="$1"
    local _port="$2"
    local _times="$3"
    local _interval="$4"

    if [ -z "$_times" ]; then
        _times=10
    fi

    if [ -z "$_interval" ]; then
        _interval=5
    fi

    for i in `seq 1 $_times`; do
      sleep $_interval
      nc -z $_host $_port && return 0
      _info "$_host:$_port is unreachable. Waiting..."
    done
    _warn "$_host:$_port is unreachable."
    return 1
}
function _isYes() {
    # Unlike other languages, 0 is nearly same as True in shell script
    local _answer="$1"

    if [ $# -eq 0 ]; then
        _answer="${__LAST_ANSWER}"
    fi

    if [[ "${_answer}" =~ $_YES_REGEX ]]; then
        #_log "$FUNCNAME: \"${_answer}\" matchs."
        return 0
    elif [[ "${_answer}" =~ $_TEST_REGEX ]]; then
        eval "${_answer}" && return 0
    fi

    return 1
}
function _trim() {
    local _string="$1"
    echo "${_string}" | sed -e 's/^ *//g' -e 's/ *$//g'
}
function _isCmd() {
    local _cmd="$1"

    if command -v "$_cmd" &>/dev/null ; then
        return 0
    else
        return 1
    fi
}
function _isNotEmptyDir() {
    local _dir_path="$1"

    # If path is empty, treat as eampty
    if [ -z "$_dir_path" ]; then return 1; fi

    # If path is not directory, treat as eampty
    if [ ! -d "$_dir_path" ]; then return 1; fi

    if [ "$(ls -A ${_dir_path})" ]; then
        return 0
    else
        return 1
    fi
}
function _isUrl() {
    local _url="$1"

    if [ -z "$_url" ]; then
        return 1
    fi

    if [[ "$_url" =~ $_URL_REGEX ]]; then
        return 0
    fi

    return 1
}
function _isUrlButNotReachable() {
    local _url="$1"

    if ! _isUrl "$_url" ; then
        return 1
    fi

    if curl --output /dev/null --silent --head --fail "$_url" ; then
        return 1
    fi

    # Return true only if URL is NOT reachable
    return 0
}
function _split() {
    local _rtn_var_name="$1"
    local _string="$2"
    local _delimiter="${3-,}"
    local _original_IFS="$IFS"
    eval "IFS=\"$_delimiter\" read -a $_rtn_var_name <<< \"$_string\""
    IFS="$_original_IFS"
}
function _trim() {
    local _string="$1"
    echo "${_string}" | sed -e 's/^ *//g' -e 's/ *$//g'
}
function _escape_sed() {
	local _str="$1"
	local _escape_single_quote="$2"

	if _isYes "$_escape_single_quote" ; then
		local _str2="$(_escape_quote "$_str")"
		echo "$_str2" | sed "s/[][\.^$*\/&|]/\\&/g"
	else
		echo "$_str" | sed 's/[][\.^$*\/"&|]/\\&/g'
	fi
}
function _merge() {
    local _search_regex="$1"
    local _replace_str="$2"
    local _path="$3"
    grep -qE "$_search_regex" "$_path" && sed -i.bak -e "s/${_search_regex}/${_replace_str}/" "$_path" || echo "$_replace_str" >> "$_path"
}

function _info() {
    # At this moment, not much difference from _echo and _warn, might change later
    local _msg="$1"
    _echo "INFO : ${_msg}" "Y"
}
function _warn() {
    local _msg="$1"
    _echo "WARN : ${_msg}" "Y"
}
function _error() {
    local _msg="$1"
    _echo "ERROR: ${_msg}" "Y"
}
function _critical() {
    local _msg="$1"
    local _exit_code=${2-$__LAST_RC}

    if [ -z "$_exit_code" ]; then _exit_code=1; fi

    _echo "ERROR: ${_msg} (${_exit_code})" "Y" "Y"
    # FIXME: need to test this change
    if $_IS_DRYRUN ; then return ${_exit_code}; fi
    _exit ${_exit_code}
}
function _exit() {
    local _exit_code=$1

    # Forcing not to go to next step.
    echo "Please press 'Ctrl-c' again to exit."
    tail -f /dev/null

    if $_IS_SCRIPT_RUNNING; then
        exit $_exit_code
    fi
    return $_exit_code
}
function _isValidateFunc() {
    local _function_name="$1"

    # FIXME: not good way
    if [[ "$_function_name" =~ ^_is ]]; then
        typeset -F | grep "^declare -f $_function_name$" &>/dev/null
        return $?
    fi
    return 1
}

function _log() {
    # At this moment, outputting to STDOUT
    local _log_file_path="$3"
    if [ -n "$_log_file_path" ]; then
        g_LOG_FILE_PATH="$_log_file_path"
        > $g_LOG_FILE_PATH
    fi
    if [ -n "$g_LOG_FILE_PATH" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $@" | tee -a $g_LOG_FILE_PATH
    else
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $@" 1>&2
    fi
}

function _echo() {
    local _msg="$1"
    local _stderr="$2"
    
    if _isYes "$_stderr" ; then
        echo -e "$_msg" 1>&2
    else 
        echo -e "$_msg"
    fi
}

list() {
    local _name="$1"
    #local _width=$(( $(tput cols) - 2 ))
    local _tmp_txt=""

    if [[ -z "$_name" ]]; then
        (for _f in `typeset -F | grep -E '^declare -f [fp]_' | cut -d' ' -f3`; do
            #eval "echo \"--[ $_f ]\" | sed -e :a -e 's/^.\{1,${_width}\}$/&-/;ta'"
            _tmp_txt="`help "$_f" "Y"`"
            printf "%-28s%s\n" "$_f" "$_tmp_txt"
        done)
    elif [[ "$_name" =~ ^func ]]; then
        typeset -F | grep '^declare -f [fp]_' | cut -d' ' -f3
    elif [[ "$_name" =~ ^glob ]]; then
        set | grep ^[g]_
    elif [[ "$_name" =~ ^resp ]]; then
        set | grep ^[r]_
    fi
}
help() {
    local _function_name="$1"
    local _doc_only="$2"

    if [ -z "$_function_name" ]; then 
        echo "help <function name>"
        echo ""
        list "func"
        echo ""
        return
    fi

    if [[ "$_function_name" =~ ^[fp]_ ]]; then
        local _code="$(type $_function_name 2>/dev/null | grep -v "^${_function_name} is a function")"
        if [ -z "$_code" ]; then
            _echo "Function name '$_function_name' does not exist."
            return 1
        fi

        local _eval="$(echo -e "${_code}" | awk '/__doc__=/,/;/')"
        eval "$_eval"

        if [ -z "$__doc__" ]; then
            echo "No help information in function name '$_function_name'."
        else
            echo -e "$__doc__"
        fi

        if ! _isYes "$_doc_only"; then
            local _params="$(type $_function_name 2>/dev/null | grep -iP '^\s*local _[^_].*?=.*?\$\{?[1-9]' | grep -v awk)"
            if [ -n "$_params" ]; then
                echo ""
                echo "Parameters:"
                echo -e "$_params"
            fi
        
            echo ""
            _ask "Show source code?" "N"
            if _isYes ; then
                echo ""
                echo -e "${_code}" | less
            fi
        fi
    else
        _echo "Unsupported Function name '$_function_name'."
        return 1
    fi
}



### main() ############################################################

if [ "$0" = "$BASH_SOURCE" ]; then
    # parsing command options
    while getopts "r:f:isaUh" opts; do
        case $opts in
            a)
                _AUTO_SETUP_HDP="Y"
                _SETUP_HDP="Y"
                ;;
            i)
                _SETUP_HDP="Y"
                ;;
            s)
                _START_HDP="Y"
                ;;
            r)
                _RESPONSE_FILEPATH="$OPTARG"
                ;;
            f)
                _FUNCTION_NAME="$OPTARG"
                ;;
            U)
                _SKIP_UPDATE_CHECK="Y"
                ;;
            h)
                usage | less
                exit 0
        esac
    done

    # Root check
    if [ "$USER" != "root" ]; then
        echo "Sorry, at this moment, only 'root' user is supported"
        exit 1
    fi

    # Supported OS check
    grep -i 'Ubuntu 1[46]\.' /etc/issue.net &>/dev/null
    if [ $? -ne 0 ]; then
        if [ "$g_UNAME_STR" == "Darwin" ]; then
            echo "Detected Mac OS"
            which docker &>/dev/null
            if [ $? -ne 0 ]; then
                echo "Sorry, at this moment, installing docker manually is required for Mac"
                echo "Please check https://docs.docker.com/engine/installation/mac/"
                exit 1
            fi
        else
            _ask "This script may not work with this OS. Are you sure?" "N"
            if ! _isYes; then echo "Bye"; exit; fi
        fi
    fi

    _IS_SCRIPT_RUNNING=true

    if _isYes "$_SETUP_HDP"; then
        if _isYes "$_AUTO_SETUP_HDP" && [ -z "$_RESPONSE_FILEPATH" ]; then
            _RESPONSE_FILEPATH="$g_LATEST_RESPONSE_URL"
        fi
        f_update_check
        p_interview_or_load

        if ! _isYes "$_AUTO_SETUP_HDP"; then
            _ask "Would you like to start setting up this host?" "Y"
            if ! _isYes; then echo "Bye"; exit; fi
            if ! _isYes "$r_DOCKER_KEEP_RUNNING"; then
                _ask "Would you like to stop all running containers now?" "Y"
                if _isYes; then f_docker_stop_all; fi
            fi
        else
            if ! _isYes "$r_DOCKER_KEEP_RUNNING"; then
                _info "Stopping all docker containers..."
                f_docker_stop_all
            fi
        fi

        g_START_TIME="`date -u`"
        p_host_setup
        g_END_TIME="`date -u`"
        echo "Started at : $g_START_TIME"
        echo "Finished at: $g_END_TIME"
        exit 0
    elif [ -n "$_FUNCTION_NAME" ]; then
        # TODO: not good validation
        if [[ "$_FUNCTION_NAME" =~ ^[fph]_ ]]; then
            f_loadResp
            eval "$_FUNCTION_NAME"
            exit 0
        fi
        _error "$_MAYBE_FUNCTION_NAME is not an available function name."
        exit 1
    elif _isYes "$_START_HDP"; then
        f_update_check
        f_loadResp
        p_hdp_start
        exit 0
    else
        usage | less
        exit 0
    fi
else
    _info "You may want to run 'f_loadResp' to load your response file"
fi

#!/usr/bin/env bash

SSH_PLUGIN_CACHE_CONFIG=${LED_CACHE_USER_DIR}/sshconfig

# plugin

# Plugin usage:
#   led ssh [command] [-h|--help]
#
# Commands :
#   in          Open console on server
#   list        List available servers
#
# If no command is provided, the command 'in' is the default one.
#
# @autocomplete ssh: in list --user --server
# @autocomplete ssh --server: [led ssh list -q]
# @autocomplete ssh --user: dev root
# @autocomplete ssh -s: [led ssh list -q]
# @autocomplete ssh -u: dev root
ssh_plugin() {
  local command=$1
  ssh_do_cache
  readonly SSH_PLUGIN_CACHE_CONFIG
  case $command in
    in) ssh_in "$@" ;;
    list) ssh_list "$@" ;;
    *) ssh_in "$@" ;;
  esac
}

# list
# Usage: led ssh list
#
# List configured servers with SSH access
# Options
#   -q, --quiet   Only list hosts aliases
#
# @autocomplete ssh list: --quiet
ssh_list() {

  local hostname
  local line
  local quiet

  # shellcheck disable=SC2046
  set -- $(_lib_utils_get_options "q" "quiet" "$@")

  # if quiet mode is enabled, will only print host aliases from ssh config file
  while [ -n "$#" ]; do
    case $1 in
      --quiet | -q)
        quiet="quiet"
        shift
        ;;
      --)
        shift
        break
        ;;
    esac
  done

  local hostname host host_aliases port user
  local str_hostinfo
  local key value

  local sshconfig_data
  # generate list of sshconfig of some keywords with their value. One line by 'Host' keyword found
  # handled keyword: Host, Hostname, Port, User
  #
  # sample output format:
  # Host=host1 host1_alias | Hostname=foo1.tld | Port=2222 |
  # Host=host2 | Hostname=foo2.tld | User=jdoe
  sshconfig_data=$(awk 'BEGIN {IGNORECASE = 1; flag = 1 }
                 flag {
                   if ($1 == "Host") { $1=""; H=substr($0,2); data=""; $1="Host" }
                   if ($1 ~ /^(Host|Hostname|Port|User)$/) {
                    key=$1; $1=""; value=substr($0,2);
                    data = data key "=" value " | "
                   }
                   config[H]=data
                 }
                 /Host /{ flag=1; }
                 END { for (key in config) { printf "%s\n", config[key] } }' \
    "${SSH_PLUGIN_CACHE_CONFIG}" | sort)

  # raw data, for debugging
  #echo "${sshconfig_data}"

  local duplicated_hosts=()
  local host_extras
  while read -r line; do
    host_aliases=
    hostname=
    port=
    user=
    while IFS='=' read -r -d '|' key value; do
      # trim spaces
      read -r key <<<"$key"
      read -r value <<<"$value"
      # escape non-printable character with blackslash
      value=$(printf "%q" "${value}")

      # search for key in lowercase
      case ${key,,} in
        host) host_aliases=$value ;;
        hostname) hostname=$value ;;
        port) port=$value ;;
        user) user=$value ;;
      esac
    done <<<"${line}"

    for host in ${host_aliases}; do
      host_extras=()
      ## check host alias
      # A host alias from a Host line with many aliases has a blackslash at the end
      [[ "${host: -1}" == "\\" ]] && host=${host::-1}

      if ! [[ $host =~ ^[a-zA-Z0-9._-]+$ ]]; then
        # skip host with other characters (like wildcard)
        continue
      fi

      if in_array "${host}" "${host_displayed[@]}"; then
        duplicated_hosts+=("$host")
        continue
      fi

      host_displayed+=("${host}")
      if [ -n "${quiet}" ]; then
        echo "${host}"
      else
        [[ -n "${port}" ]] && host_extras+=("port: $port")
        [[ -n "${user}" ]] && host_extras+=("user: $user")
        str_hostinfo="${hostname}"
        [[ ${#host_extras[*]} -ge 1 ]] && str_hostinfo+=" [${host_extras[*]}]"
        print_padded "${host}" "${str_hostinfo}"
      fi
    done

  done <<<"${sshconfig_data}"

  if [[ ${#duplicated_hosts[*]} -ge 1 && -z "${quiet}" ]]; then
    echo -e >&2 "\\n[SKIPPED] Host(s) in '${duplicated_hosts[*]}' duplicated! Please check your sshconfig files"
  fi
}

# in
# Usage: led ssh in [OPTIONS]
#
# Connect to servers using SSH.
# An sshconfig file must exist in the global or local directory .led
#
# Options
#   -s, --server   Server name to use
#   -u, --user     Override user to use
#
# You can define options using configuration keys:
# default.ssh    myhost
#
# @autocomplete ssh in: --user --server
# @autocomplete ssh in --server: [led ssh list -q]
# @autocomplete ssh in --user: dev root
# @autocomplete ssh in -s: [led ssh list -q]
# @autocomplete ssh in -u: dev root
ssh_in() {
  local user
  local server
  local ssh_remote

  local default_ssh_server
  default_ssh_server="$(_config_get_value default.ssh)"

  # shellcheck disable=SC2046
  set -- $(_lib_utils_get_options "u:s:l" "user:,server:" "$@")

  while [ -n "$#" ]; do
    case $1 in
      -u | --user)
        user=$2
        shift 2
        ;;
      -s | --server)
        server=$2
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "bad option: $1"
        shift
        break
        ;;
    esac
  done

  server=${server:-"${default_ssh_server}"}

  if [ -z "${server}" ]; then
    fallback_deprecated_ssh "${user}" "${server}" "$@"
    help ssh
    exit
  fi

  local ssh_version
  ssh_version=$(command ssh -V 2>&1)
  # only keep OpenSSH version
  ssh_version=${ssh_version%,*}

  local ssh_host_aliases
  # only get host aliases
  mapfile -t ssh_host_aliases < <(ssh_list --quiet)

  # test if the server is a Host entry defined in ssh config file
  if in_array "${server}" "${ssh_host_aliases[@]}"; then
    # if yes, connect to the remote server
    if [ -n "${user}" ]; then
      ssh_remote="${user}@${server}"
    else
      ssh_remote="${server}"
    fi
    echo "[SSH client '${ssh_version}']"
    command ssh "${ssh_remote}" -F "${SSH_PLUGIN_CACHE_CONFIG}"
  else
    echo -e "Can't find server named '${server}'\\n"
    fallback_deprecated_ssh "${user}" "${server}" "$@"
    exit 1
  fi
}

# If ssh command is known as deprecated yet, fallback to docker exec
fallback_deprecated_ssh() {
  if key_in_array "ssh" in DEPRECATED_COMMANDS; then
    echo "Warning: Deprecated command. Please use 'led in' to get console on container or install 'ssh' plugin to connect servers."

    # get command from remaining arguments
    local user=${1:-"dev"}
    shift
    local server=${1:-"apache"}
    shift
    local cmd=${*:-$cmd}
    echo "trying to find a container named '${server}':"

    _docker_exec "${user}" "${server}" "${cmd}"
  fi
  return 0
}

# Generate single file with all ssh config files founds
ssh_do_cache() {
  local f

  local sshconfig=()
  sshconfig+=(".led/sshconfig")
  # avoid to read same .led/sshconfig twice
  [ "${PWD}" != "${HOME}" ] && sshconfig+=("${HOME}/.led/sshconfig")
  sshconfig+=("${SCRIPT_DIR}/etc/sshconfig")

  cat /dev/null >"${SSH_PLUGIN_CACHE_CONFIG}"
  for f in "${sshconfig[@]}"; do
    [ -f "$f" ] && cat "$f" >>"${SSH_PLUGIN_CACHE_CONFIG}"
  done

  return 0
}

ssh_get_sshconfig() {
  if [[ -f "${SSH_PLUGIN_CACHE_CONFIG}" ]]; then
    echo "${SSH_PLUGIN_CACHE_CONFIG}"
  fi
}

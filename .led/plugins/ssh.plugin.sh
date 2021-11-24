#!/usr/bin/env bash

# not ready for current led version
#readonly SSHCONFIG_FILE=".led/sshconfig"
SSHCONFIG_FILE=".led/sshconfig"

# plugin

# Plugin usage:
#   led ssh [command] [-h|--help]
#
# Commands:
#   in          Open console on server
#   list        List available servers
#
# If no command is provided, the command 'in' is the default one.
#
# @autocomplete ssh: in list --user --server
# @autocomplete ssh --server: [led ssh list -q]
# @autocomplete ssh -s: [led ssh list -q]
ssh_plugin() {
  local command=$1

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

  if [[ ! -f "${SSHCONFIG_FILE}" ]]; then
     [[ -z "${quiet}" ]] && echo "${SSHCONFIG_FILE} file not found" >&2
    return 1
  elif [[ ! -s "${SSHCONFIG_FILE}" ]]; then
    [[  -z "${quiet}" ]] && echo "${SSHCONFIG_FILE} file is empty!" >&2
    return 1
  fi

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
    "${SSHCONFIG_FILE}" | sort)

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
    echo -e "\\n[SKIPPED] Host(s) in '${duplicated_hosts[*]}' duplicated! Please check your sshconfig files" >&2
  fi
}

# in
# Usage: led ssh in [OPTIONS]
#
# Connect to servers using SSH.
# An .led/sshconfig file must exist in current directory
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
# @autocomplete ssh in -s: [led ssh list -q]
ssh_in() {
  local user
  local server
  local ssh_remote

  local default_ssh_server
  default_ssh_server="$(_config_get_value default.ssh)"

  # shellcheck disable=SC2046
  set -- $(_lib_utils_get_options "u:s:" "user:,server:" "$@")

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
    help ssh
    return 1
  fi

  local ssh_version
  ssh_version=$(command ssh -V 2>&1)
  # only keep OpenSSH version
  ssh_version=${ssh_version%,*}

  local ssh_host_aliases
  # only get host aliases
  mapfile -t ssh_host_aliases < <(ssh_list --quiet)
  if [[ ${#ssh_host_aliases[@]} -eq 0 ]]; then
    echo "no host alias found"
    return 1
  fi

  # test if the server is a Host entry defined in ssh config file
  if in_array "${server}" "${ssh_host_aliases[@]}"; then
    # if yes, connect to the remote server
    if [ -n "${user}" ]; then
      ssh_remote="${user}@${server}"
    else
      ssh_remote="${server}"
    fi
    echo "[SSH client '${ssh_version}']"
    ssh_exec "${ssh_remote}"
  else
    echo -e "Can't find server named '${server}'\\n"
    return 1
  fi
}

#
# ssh_exec <host> <command>
# if command is not set, run SSH interactivly
#
ssh_exec() {
  local ssh_bin

  local server=$1
  local command=$2

  if [[ $# -eq 0 ]]; then
    echo "ssh_exec <server> [<command>]" >&2
    return 1
  fi

  local ssh_options=()
  ssh_add_sshconfig_option ssh_options

  ssh_options+=(-o"PreferredAuthentications=publickey")

  ssh_bin=$(type -P ssh)
  if [[ -n "${command}" ]]; then
    ssh_options+=(-n)
    echo -e ":: [host: '${server}'] Executing SSH command '${command}'" >&2
    ${ssh_bin} "${ssh_options[@]}" "${server}" -- "${command}"
  else
    echo -e ":: [host: '${server}'] Interactive connection" >&2
    ${ssh_bin} "${ssh_options[@]}" "${server}"
  fi
}

# Simple wrapper to scp which handle .led/sshconfig file by default
#
# ssh_scp <source> <target>
ssh_scp() {
  local scp_bin

  if [[ $# -lt 2 ]]; then
    echo "ssh_scp <source> <target>" >&2
    return 1
  fi

  local scp_options=()
  ssh_add_sshconfig_option scp_options
  scp_options+=(-o"PreferredAuthentications=publickey")

  scp_bin=$(type -P scp)
  echo -e ":: [host: '${server}'] Executing SCP command '$*'" >&2
  ${scp_bin} "${scp_options[@]}" "$@"
}

# add ssh/scp option to a defined array if sshconfig file exists
#
# example:
# ssh_add_sshconfig_option array_name
# ssh "${array_name[@]}" ...
# scp "${array_name[@]}" ...
ssh_add_sshconfig_option() {
  local ssh_opt
  declare -n ssh_opt=$1
  if [[ -f "${SSHCONFIG_FILE}" ]]; then
    ssh_opt+=(-F "${SSHCONFIG_FILE}")
  fi
}

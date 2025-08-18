#!/bin/bash

# --- Variables ---
# --- For initialization ---
readonly GITHUB_REPOSITORY="https://raw.githubusercontent.com/Temporalitas/ipv6-proxy-server/master"
readonly SCRIPT_VERSION="2.0.0"
readonly PROXY_SERVICE_NAME="ipv6-proxy-server.service"
# --- For internal use ---
CONFIG_FILE_PATH=""
# --- For runtime ---
IPV6_SUBNET=""
IPV6_SUBNET_SIZE=""
PROXIES_COUNT=0
PROXIES_TYPE="http"
PROXY_USERNAME=""
PROXY_PASSWORD=""
ROTATING_INTERVAL=0 # In minutes, 0 to disable
NETWORK_INTERFACE_NAME=""
NETWORK_INTERFACE_IPV4_ADDRESS=""
NETWORK_INTERFACE_IPV6_ADDRESS=""
NETWORK_INTERFACE_IPV6_MASK=""
# --- For uninstallation ---
UNINSTALL=false
# --- For info ---
INFO=false

# --- Functions ---
function get_config_file_path() {
  local config_file_path="/etc/ipv6-proxy-server/config.cfg"
  echo "$config_file_path"
}

function get_proxies_list_file_path() {
  local proxies_list_file_path="/etc/ipv6-proxy-server/proxies.list"
  echo "$proxies_list_file_path"
}

function get_random_ipv6_address() {
  local ipv6_subnet="$1"
  local ipv6_subnet_size="$2"
  local random_ipv6_address=""
  if [[ "$ipv6_subnet_size" -eq 64 ]]; then
    local random_part_1
    local random_part_2
    random_part_1=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 4)
    random_part_2=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 4)
    random_ipv6_address="${ipv6_subnet}${random_part_1}:${random_part_2}"
  elif [[ "$ipv6_subnet_size" -eq 48 ]]; then
    local random_part_1
    local random_part_2
    local random_part_3
    random_part_1=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 4)
    random_part_2=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 4)
    random_part_3=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 4)
    random_ipv6_address="${ipv6_subnet}${random_part_1}:${random_part_2}:${random_part_3}"
  fi
  echo "$random_ipv6_address"
}

function install_dependencies() {
  echo "Installing dependencies..."
  apt-get update >/dev/null
  apt-get install -y curl wget unzip make >/dev/null
}

function detect_network_interface() {
  echo "Detecting network interface..."
  NETWORK_INTERFACE_NAME=$(ip -o -4 route show to default | awk '{print $5}')
  NETWORK_INTERFACE_IPV4_ADDRESS=$(ip -o -4 addr show dev "$NETWORK_INTERFACE_NAME" | awk '{print $4}' | cut -d'/' -f1)
  NETWORK_INTERFACE_IPV6_ADDRESS=$(ip -o -6 addr show dev "$NETWORK_INTERFACE_NAME" | awk '{print $4}' | cut -d'/' -f1 | head -n 1)
  if [[ -z "$NETWORK_INTERFACE_IPV6_ADDRESS" ]]; then
    echo "Error: No IPv6 address found on interface $NETWORK_INTERFACE_NAME"
    exit 1
  fi
  if [[ "$IPV6_SUBNET_SIZE" -eq 64 ]]; then
    NETWORK_INTERFACE_IPV6_MASK="64"
    IPV6_SUBNET=$(echo "$NETWORK_INTERFACE_IPV6_ADDRESS" | cut -d':' -f1-4)
    IPV6_SUBNET="${IPV6_SUBNET}:"
  elif [[ "$IPV6_SUBNET_SIZE" -eq 48 ]]; then
    NETWORK_INTERFACE_IPV6_MASK="48"
    IPV6_SUBNET=$(echo "$NETWORK_INTERFACE_IPV6_ADDRESS" | cut -d':' -f1-3)
    IPV6_SUBNET="${IPV6_SUBNET}:"
  fi
}

function configure_network_interface() {
  echo "Configuring network interface..."
  local random_ipv6_addresses_count=$((PROXIES_COUNT * 2))
  local random_ipv6_addresses=()
  for ((i = 0; i < random_ipv6_addresses_count; i++)); do
    random_ipv6_addresses+=("$(get_random_ipv6_address "$IPV6_SUBNET" "$IPV6_SUBNET_SIZE")")
  done
  for random_ipv6_address in "${random_ipv6_addresses[@]}"; do
    ip addr add "${random_ipv6_address}/${NETWORK_INTERFACE_IPV6_MASK}" dev "$NETWORK_INTERFACE_NAME"
  done
}

function install_3proxy() {
  echo "Installing 3proxy..."
  local three_proxy_archive_url="https://github.com/3proxy/3proxy/archive/0.9.4.zip"
  local three_proxy_archive_path="/tmp/3proxy.zip"
  local three_proxy_archive_unpacked_path="/tmp/3proxy-0.9.4"
  wget -q -O "$three_proxy_archive_path" "$three_proxy_archive_url"
  unzip -q "$three_proxy_archive_path" -d /tmp
  make -C "$three_proxy_archive_unpacked_path" -f Makefile.Linux
  cp "$three_proxy_archive_unpacked_path/bin/3proxy" /usr/local/bin/
  rm -rf "$three_proxy_archive_path" "$three_proxy_archive_unpacked_path"
}

function configure_3proxy() {
  echo "Configuring 3proxy..."
  local three_proxy_config_file_path="/etc/3proxy/3proxy.cfg"
  mkdir -p /etc/3proxy
  rm -f "$three_proxy_config_file_path"
  if [[ "$PROXIES_TYPE" == "http" ]]; then
    local proxy_command="proxy"
  elif [[ "$PROXIES_TYPE" == "socks5" ]]; then
    local proxy_command="socks"
  fi
  echo "daemon" >>"$three_proxy_config_file_path"
  echo "nserver [2001:4860:4860::8888]" >>"$three_proxy_config_file_path"
  echo "nserver [2001:4860:4860::8844]" >>"$three_proxy_config_file_path"
  echo "nscache 65536" >>"$three_proxy_config_file_path"
  echo "timeouts 1 5 30 60 180 1800 15 60" >>"$three_proxy_config_file_path"
  echo "log /var/log/3proxy.log" >>"$three_proxy_config_file_path"
  if [[ -n "$PROXY_USERNAME" ]] && [[ -n "$PROXY_PASSWORD" ]]; then
    echo "auth strong" >>"$three_proxy_config_file_path"
    echo "users $PROXY_USERNAME:CL:$PROXY_PASSWORD" >>"$three_proxy_config_file_path"
    echo "allow $PROXY_USERNAME" >>"$three_proxy_config_file_path"
  fi
  local starting_port=30000
  local proxies_list=()
  for ((i = 0; i < PROXIES_COUNT; i++)); do
    local port=$((starting_port + i))
    local outgoing_ipv6_address
    outgoing_ipv6_address=$(get_random_ipv6_address "$IPV6_SUBNET" "$IPV6_SUBNET_SIZE")
    echo "$proxy_command -p$port -i$NETWORK_INTERFACE_IPV4_ADDRESS -e$outgoing_ipv6_address" >>"$three_proxy_config_file_path"
    if [[ -n "$PROXY_USERNAME" ]] && [[ -n "$PROXY_PASSWORD" ]]; then
      proxies_list+=("$NETWORK_INTERFACE_IPV4_ADDRESS:$port:$PROXY_USERNAME:$PROXY_PASSWORD")
    else
      proxies_list+=("$NETWORK_INTERFACE_IPV4_ADDRESS:$port")
    fi
  done
  local proxies_list_file_path
  proxies_list_file_path=$(get_proxies_list_file_path)
  mkdir -p "$(dirname "$proxies_list_file_path")"
  for proxy in "${proxies_list[@]}"; do
    echo "$proxy" >>"$proxies_list_file_path"
  done
}

function create_service() {
  echo "Creating service..."
  local service_file_path="/etc/systemd/system/$PROXY_SERVICE_NAME"
  echo "[Unit]" >"$service_file_path"
  echo "Description=3proxy Proxy Server" >>"$service_file_path"
  echo "After=network.target" >>"$service_file_path"
  echo "[Service]" >>"$service_file_path"
  echo "Type=simple" >>"$service_file_path"
  echo "ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg" >>"$service_file_path"
  echo "ExecStop=/bin/kill \$(cat /var/run/3proxy.pid)" >>"$service_file_path"
  echo "RemainAfterExit=yes" >>"$service_file_path"
  echo "Restart=always" >>"$service_file_path"
  echo "[Install]" >>"$service_file_path"
  echo "WantedBy=multi-user.target" >>"$service_file_path"
  systemctl daemon-reload
  systemctl enable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
}

function start_service() {
  echo "Starting service..."
  systemctl start "$PROXY_SERVICE_NAME"
}

function create_cronjob_for_rotation() {
  echo "Creating cronjob for rotation..."
  local cronjob_file_path="/etc/cron.d/ipv6-proxy-server-rotation"
  local cronjob_script_path="/usr/local/bin/ipv6-proxy-server-rotation.sh"
  local cronjob_script_url="$GITHUB_REPOSITORY/ipv6-proxy-server-rotation.sh"
  wget -q -O "$cronjob_script_path" "$cronjob_script_url"
  chmod +x "$cronjob_script_path"
  echo "*/$ROTATING_INTERVAL * * * * root $cronjob_script_path >/dev/null 2>&1" >"$cronjob_file_path"
}

function save_config() {
  echo "Saving config..."
  mkdir -p "$(dirname "$CONFIG_FILE_PATH")"
  echo "IPV6_SUBNET=$IPV6_SUBNET" >"$CONFIG_FILE_PATH"
  echo "IPV6_SUBNET_SIZE=$IPV6_SUBNET_SIZE" >>"$CONFIG_FILE_PATH"
  echo "PROXIES_COUNT=$PROXIES_COUNT" >>"$CONFIG_FILE_PATH"
  echo "PROXIES_TYPE=$PROXIES_TYPE" >>"$CONFIG_FILE_PATH"
  echo "PROXY_USERNAME=$PROXY_USERNAME" >>"$CONFIG_FILE_PATH"
  echo "PROXY_PASSWORD=$PROXY_PASSWORD" >>"$CONFIG_FILE_PATH"
  echo "ROTATING_INTERVAL=$ROTATING_INTERVAL" >>"$CONFIG_FILE_PATH"
  echo "NETWORK_INTERFACE_NAME=$NETWORK_INTERFACE_NAME" >>"$CONFIG_FILE_PATH"
  echo "NETWORK_INTERFACE_IPV4_ADDRESS=$NETWORK_INTERFACE_IPV4_ADDRESS" >>"$CONFIG_FILE_PATH"
  echo "NETWORK_INTERFACE_IPV6_ADDRESS=$NETWORK_INTERFACE_IPV6_ADDRESS" >>"$CONFIG_FILE_PATH"
  echo "NETWORK_INTERFACE_IPV6_MASK=$NETWORK_INTERFACE_IPV6_MASK" >>"$CONFIG_FILE_PATH"
}

function load_config() {
  if [[ -f "$CONFIG_FILE_PATH" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE_PATH"
  else
    echo "Error: Config file not found"
    exit 1
  fi
}

function uninstall() {
  echo "Uninstalling..."
  systemctl stop "$PROXY_SERVICE_NAME"
  systemctl disable "$PROXY_SERVICE_NAME" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$PROXY_SERVICE_NAME"
  systemctl daemon-reload
  rm -f /usr/local/bin/3proxy
  rm -rf /etc/3proxy
  rm -f /var/log/3proxy.log
  rm -f /etc/cron.d/ipv6-proxy-server-rotation
  rm -f /usr/local/bin/ipv6-proxy-server-rotation.sh
  local proxies_list_file_path
  proxies_list_file_path=$(get_proxies_list_file_path)
  rm -f "$proxies_list_file_path"
  rm -f "$CONFIG_FILE_PATH"
  echo "Uninstallation complete"
}

function info() {
  echo "Version: $SCRIPT_VERSION"
  echo "Config file path: $CONFIG_FILE_PATH"
  local proxies_list_file_path
  proxies_list_file_path=$(get_proxies_list_file_path)
  echo "Proxies list file path: $proxies_list_file_path"
  echo "---"
  # Print all variables from config file except empty username and password
  # read config file line by line and print
  while IFS= read -r line; do
    if [[ "$line" != "PROXY_USERNAME="* ]] && [[ "$line" != "PROXY_PASSWORD="* ]]; then
      echo "$line"
    elif [[ "$line" == "PROXY_USERNAME="* ]] && [[ -n "$PROXY_USERNAME" ]]; then
      echo "$line"
    elif [[ "$line" == "PROXY_PASSWORD="* ]] && [[ -n "$PROXY_PASSWORD" ]]; then
      echo "$line"
    fi
  done <"$CONFIG_FILE_PATH"
  echo "---"
  echo "Service status:"
  systemctl status "$PROXY_SERVICE_NAME" --no-pager
}

# --- Main ---
# --- Check for root ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root"
  exit 1
fi

# --- Arguments parsing ---
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
  -s | --subnet)
    IPV6_SUBNET_SIZE="$2"
    shift
    shift
    ;;
  -c | --proxy-count)
    PROXIES_COUNT="$2"
    shift
    shift
    ;;
  -t | --proxies-type)
    PROXIES_TYPE="$2"
    shift
    shift
    ;;
  -u | --username)
    PROXY_USERNAME="$2"
    shift
    shift
    ;;
  -p | --password)
    PROXY_PASSWORD="$2"
    shift
    shift
    ;;
  -r | --rotating-interval)
    ROTATING_INTERVAL="$2"
    shift
    shift
    ;;
  --uninstall)
    UNINSTALL=true
    shift
    ;;
  --info)
    INFO=true
    shift
    ;;
  *)
    echo "Unknown argument: $1"
    exit 1
    ;;
  esac
done

# --- START of modification ---
# Generate random username and password if not provided by the user
if [ -z "$PROXY_USERNAME" ] && [ -z "$PROXY_PASSWORD" ]; then
  echo "Username and password not provided, generating random credentials..."
  PROXY_USERNAME=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
  PROXY_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)
  echo "Generated Username: $PROXY_USERNAME"
  echo "Generated Password: $PROXY_PASSWORD"
fi
# --- END of modification ---

CONFIG_FILE_PATH=$(get_config_file_path)

if [[ "$UNINSTALL" = true ]]; then
  load_config
  uninstall
  exit 0
fi

if [[ "$INFO" = true ]]; then
  load_config
  info
  exit 0
fi

# Check for required arguments
if [[ -z "$IPV6_SUBNET_SIZE" ]] || [[ "$PROXIES_COUNT" -eq 0 ]]; then
  echo "Usage: $0 -s <subnet_size> -c <proxy_count> [options]"
  echo "Required arguments:"
  echo "  -s, --subnet <subnet_size>      IPv6 subnet size (64 or 48)"
  echo "  -c, --proxy-count <proxy_count> Number of proxies to create"
  echo "Options:"
  echo "  -t, --proxies-type <type>         Proxy type (http or socks5), default: http"
  echo "  -u, --username <username>         Proxy username"
  echo "  -p, --password <password>         Proxy password"
  echo "  -r, --rotating-interval <minutes> Rotating interval in minutes (0 to disable), default: 0"
  echo "  --uninstall                       Uninstall the proxy server"
  echo "  --info                            Show information about the proxy server"
  exit 1
fi

install_dependencies
detect_network_interface
configure_network_interface
install_3proxy
configure_3proxy
create_service
start_service
if [[ "$ROTATING_INTERVAL" -gt 0 ]]; then
  create_cronjob_for_rotation
fi
save_config

echo "Done"
echo "Your proxies are saved in $(get_proxies_list_file_path)"

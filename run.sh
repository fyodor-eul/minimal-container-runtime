#!/usr/bin/env bash

usage() {
  echo "Usage: $0 <install|run> <container-name>"
  exit 1
}

if [[ -z $1 ]] || [[ -z $2 ]]; then
  usage
fi

ACTION="$1" # `install` or `run`
CONTAINER_NAME="$2"

BASE_DIR="$HOME/.conruntime"
CONTAINER_DIR="$BASE_DIR/$CONTAINER_NAME"
ROOTFS="$BASE_DIR/$CONTAINER_NAME/rootfs"
BASE_LINK="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz"

USER_ID=$(id -u)
GROUP_ID=$(id -g)

BRIDGE="conbr0"
BRIDGE_IP="10.0.0.1/24"
SUBNET="10.0.0.0/24"
OUT_IFACE=$(ip route show default | awk '{print $5; exit}')

bootstrap_rootfs() {

  if [[ -d "$ROOTFS/bin" ]]; then
    echo "[*] rootfs already exists, skipping download"
    return
  fi

  echo "[*] Bootstraping rootfs for $CONTAINER_NAME"
  mkdir -p "$ROOTFS"
  if [ ! -f "$CONTAINER_DIR/base.tar.gz" ]; then
    curl -L -o "$CONTAINER_DIR/base.tar.gz" "$BASE_LINK"
  fi
  tar -zxf "$CONTAINER_DIR/base.tar.gz" -C "$ROOTFS"
}

setup_network() {
  echo "[*] Setting up Bridge"
  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo "[*] Bridge already exists skipping"
  else
    sudo ip link add name "$BRIDGE" type bridge
    sudo ip addr add "$BRIDGE_IP" dev "$BRIDGE"
    sudo ip link set "$BRIDGE" up
  fi

  echo "[*] Enabling IP Forwarding"
  sudo sysctl -w net.ipv4.ip_forward=1

  echo "Adding Masquerade rule via $OUT_IFACE"
  if sudo iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$OUT_IFACE" -j MASQUERADE 2>/dev/null; then
    echo "Masquerade rule already present skipping"
  else
    sudo iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$OUT_IFACE" -j MASQUERADE
  fi
}

pivot_root_setup() {
  echo 'pivot_root setup'
}

do_run() {
  bootstrap_rootfs

  subuid_id=$(cat /etc/subuid | grep "^$USER:" | cut -d: -f2)
  subuid_count=$(cat /etc/subuid | grep "^$USER:" | cut -d: -f3)
  subgid_id=$(cat /etc/subgid | grep "^$USER:" | cut -d: -f2)
  subgid_count=$(cat /etc/subgid | grep "^$USER:" | cut -d: -f3)

  if [[ -z "$subuid_id" || -z "$subgid_id" ]]; then
    echo "[!] No /etc/subuid or /etc/subgid entry for $(id -un). Add one first." >&2
    exit 1
  fi

  echo "[*] Starting the container $CONTAINER_NAME"
  network_ready="$CONTAINER_DIR/network-ready" # synchronization file
  rm -f "$network_ready"

  set -m

  unshare --mount --pid --fork --mount-proc --ipc -C -n -u --map-users="$USER_ID",0,1 --map-users="$subuid_id",1,"$subuid_count" --map-groups="$GROUP_ID",0,1 --map-groups="$subgid_id",1,"$subgid_count" "$0" ns_init "$CONTAINER_NAME" "$network_ready" &

  container_pid=$!
  echo "[*] Container PID: $container_pid"
  setup_container_network "$container_pid"
  touch "$network_ready"
  fg %1
  #wait "$container_pid"
}

ns_init() {
  #local network_ready="$CONTAINER_DIR/network-ready"
  local network_ready="$3"

  echo "[*] Waiting for network"
  while [[ ! -f "$network_ready" ]]; do
    sleep 0.1
  done

  echo "[*] Setting up rootfs"

  mount --make-rprivate /
  mount --bind "$ROOTFS" "$ROOTFS"
  cd "$ROOTFS"

  mkdir -p ./oldroot
  pivot_root . ./oldroot

  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  hash -r

  umount -l /oldroot
  rmdir /oldroot

  #mount -t proc proc /proc
  #mount -t sysfs sys /sys

  #mount -t tmpfs tmpfs /dev
  #mkdir -p /dev/pts /dev/shm
  #mount -t devpts devpts /dev/pts
  #mount -t tmpfs tmpfs /dev/shm

  #mknod -m 666 /dev/null c 1 3
  #mknod -m 666 /dev/zero c 1 5
  #mknod -m 666 /dev/random c 1 8
  #mknod -m 666 /dev/urandom c 1 9
  #mknod -m 666 /dev/tty c 5 0
  #ln -sf /proc/self/fd /dev/fd

  export HOME=/root

  echo "[*] Dropping into shell"
  exec /bin/sh
}

setup_container_network() {
  local pid="$1"
  local veth="conveth-$CONTAINER_NAME"
  local vethBr="conbr-$CONTAINER_NAME"

  echo "[*] Creating veth pair"
  sudo ip link add name "$veth" type veth peer name "$vethBr"

  echo "[*] Connecting host side to $BRIDGE"
  sudo ip link set "$vethBr" master "$BRIDGE"
  sudo ip link set "$vethBr" up

  echo "[*] Moving container side into network namespace $pid"
  sudo ip link set "$veth" netns "$pid"

  echo "[*] Configuring container network"
  echo "[1] Adding IP"
  sudo nsenter -t "$pid" -n ip addr add 10.0.0.2/24 dev "$veth"
  echo "[1] Done"

  echo "[2] Bringing veth up"
  sudo nsenter -t "$pid" -n ip link set "$veth" up
  echo "[2] Done"

  echo "[3] Bringing loopback up"
  sudo nsenter -t "$pid" -n ip link set lo up
  echo "[3] Done"

  echo "[4] Adding default route"
  sudo nsenter -t "$pid" -n ip route add default via 10.0.0.1
  echo "[4] Done"
}

case "$ACTION" in
install)
  bootstrap_rootfs
  setup_network
  ;;
run)
  do_run
  ;;
ns_init)
  ns_init "$@"
  ;;
*)
  usage
  ;;
esac

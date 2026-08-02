#!/bin/bash
# ============================================================
#  Arch Install — observerexe-larptop
#  Фінальна претестова версія — усі відомі баги виправлено
# ============================================================
set -euo pipefail

# ============================================================
#  НАЛАШТУВАННЯ — ЗМІНЮЙ ТІЛЬКИ ТУТ
# ============================================================
SWAP_SIZE="8G"
NEW_HOSTNAME="observerexe-larptop"
USERNAME="observerexe"
TIMEZONE="Europe/Kyiv"
LOCALE_SYSTEM="en_US.UTF-8"
LOCALE_EXTRA="uk_UA.UTF-8"
KEYMAP="us"
GPU="nvidia"                          # nvidia | amd | intel
PACKAGES_EXTRA="fastfetch firefox btop cmatrix cava"

# Затримка між спробами (секунд)
RETRY_DELAY=5

# Мінімальний вільний простір для root (у ГБ)
MIN_ROOT_SIZE_GB=50

# ============================================================
#  КОЛЬОРИ ТА ДОПОМІЖНІ ФУНКЦІЇ
# ============================================================
C_G='\033[0;32m'
C_Y='\033[1;33m'
C_R='\033[0;31m'
C_NC='\033[0m'

info() { echo -e "${C_G}[*]${C_NC} $*"; }
warn() { echo -e "${C_Y}[!]${C_NC} $*"; }
err()  { echo -e "${C_R}[X]${C_NC} $*"; exit 1; }

# --- Нескінченні спроби (host) ---
retry_forever() {
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        warn "Спроба $attempt не вдалася. Повтор через ${RETRY_DELAY}с..."
        sleep "$RETRY_DELAY"
        ((attempt++))
    done
}

# --- Перевірка URL через HTTP (не ICMP!) ---
check_url() {
    local url=$1
    retry_forever curl -fsI --connect-timeout 10 "$url" >/dev/null 2>&1
}

# --- Перевірка git-репозиторію ---
check_git_repo() {
    local url=$1
    info "Перевірка доступності репозиторію: $url"
    retry_forever git ls-remote --exit-code "$url" >/dev/null 2>&1
    info "Репозиторій доступний."
}

# ============================================================
#  0. ПЕРЕВІРКИ
# ============================================================
check_root() {
    [[ $EUID -eq 0 ]] || err "Запускай від root (sudo su)"
}

check_uefi() {
    [[ -d /sys/firmware/efi/efivars ]] || \
        err "UEFI не знайдено. Потрібен UEFI-режим для dualboot."
}

check_secure_boot() {
    local sb_file="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    if [[ -f "$sb_file" ]]; then
        local sb_state
        sb_state=$(od -An -tx1 "$sb_file" | awk '{print $NF}')
        if [[ "$sb_state" == "01" ]]; then
            warn "УВАГА: Secure Boot УВІМКНЕНО!"
            if [[ "$GPU" == "nvidia" ]]; then
                warn "nvidia-open-dkms модуль НЕ завантажиться без підпису."
            fi
            warn "Вимкни Secure Boot в UEFI BIOS перед перезавантаженням."
            read -r -p "Продовжити всерівно? [y/N] " yn
            [[ "$yn" =~ ^[Yy]$ ]] || err "Скасовано. Вимкни Secure Boot і запусти знову."
        fi
    fi
}

check_network() {
    info "Перевірка інтернету (HTTP, не ICMP)..."
    check_url "https://archlinux.org"
    info "Інтернет є."
}

ensure_host_git() {
    if ! command -v git >/dev/null 2>&1; then
        info "Встановлення git на Live ISO..."
        retry_forever pacman -Sy --noconfirm --needed git
    fi
}

# ============================================================
#  1. ВИБІР ДИСКА
# ============================================================
select_disk() {
    local DISKS
    DISKS=$(lsblk -d -p -n -o NAME,SIZE,TYPE | awk '$3=="disk"{print $1, $2}')
    local COUNT
    COUNT=$(echo "$DISKS" | grep -c '^/' || true)

    if [[ "$COUNT" -eq 0 ]]; then
        err "Не знайдено жодного диска."
    elif [[ "$COUNT" -eq 1 ]]; then
        DISK=$(echo "$DISKS" | awk '{print $1}')
        info "Знайдено диск: $(echo "$DISKS" | head -1)"
        read -r -p "Використати цей диск? [Y/n] " yn
        [[ -z "$yn" || "$yn" =~ ^[Yy]$ ]] || err "Встановлення скасовано."
    else
        warn "Знайдено кілька дисків:"
        echo "$DISKS" | nl -w2 -s'. '
        read -r -p "Введи номер диска: " num
        DISK=$(echo "$DISKS" | sed -n "${num}p" | awk '{print $1}')
        [[ -n "$DISK" && -b "$DISK" ]] || err "Невірний вибір."
    fi
    export DISK
    info "Обрано диск: $DISK"
}

# ============================================================
#  2. ПОШУК EFI РОЗДІЛУ (з валідацією вводу)
# ============================================================
find_efi() {
    local EFI_COUNT
    EFI_COUNT=$(sgdisk -p "$DISK" | grep -c 'EF00' || true)

    if [[ "$EFI_COUNT" -eq 0 ]]; then
        err "Не знайдено EFI System Partition (тип EF00). Windows встановлений?"
    elif [[ "$EFI_COUNT" -eq 1 ]]; then
        EFI_NUM=$(sgdisk -p "$DISK" | awk '/EF00/{print $1; exit}')
        info "Знайдено один EFI-розділ (№$EFI_NUM)."
    else
        warn "Знайдено кілька EFI-розділів:"
        sgdisk -p "$DISK" | awk '/EF00/{print "  Розділ", $1, "-", $7}'
        while true; do
            read -r -p "Введи номер EFI-розділу (зазвичай 1): " EFI_NUM
            if sgdisk -i "$EFI_NUM" "$DISK" 2>/dev/null | grep -q "EF00"; then
                break
            fi
            warn "Розділ №$EFI_NUM не є EFI (EF00). Спробуй ще раз."
        done
    fi

    if [[ "$DISK" =~ nvme ]]; then
        EFI_PART="${DISK}p${EFI_NUM}"
    else
        EFI_PART="${DISK}${EFI_NUM}"
    fi

    info "EFI розділ: $EFI_PART"

    if ! blkid "$EFI_PART" | grep -qi 'TYPE="vfat"'; then
        warn "$EFI_PART не схожий на FAT32, але продовжуємо..."
    fi
}

# ============================================================
#  3. ОЧИЩЕННЯ СТАРИХ LINUX-РОЗДІЛІВ
# ============================================================
clean_old_partitions() {
    local HAS_OLD=0
    for num in 5 6; do
        if sgdisk -i "$num" "$DISK" >/dev/null 2>&1; then
            local GUID
            GUID=$(sgdisk -i "$num" "$DISK" | grep "Partition GUID code:" | awk '{print $4}')
            if [[ "$GUID" == "0FC63DAF-8483-4772-8E79-3D69D8477DE4" || "$GUID" == "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" ]]; then
                warn "Знайдено старий Linux-розділ ${DISK}p${num}"
                HAS_OLD=1
            else
                err "Розділ ${DISK}p${num} існує, але має невідомий тип ($GUID). Видали його вручну."
            fi
        fi
    done
    
    if [[ "$HAS_OLD" -eq 1 ]]; then
        warn "Будуть видалені старі Linux-розділи."
        read -r -p "Продовжити? [y/N] " yn
        [[ "$yn" =~ ^[Yy]$ ]] || err "Скасовано."
        
        for num in 5 6; do
            if sgdisk -i "$num" "$DISK" >/dev/null 2>&1; then
                sgdisk -d "$num" "$DISK"
                info "Видалено ${DISK}p${num}"
            fi
        done
        partprobe "$DISK"
        udevadm settle
        sleep 1
    fi
}

# ============================================================
#  4. СТВОРЕННЯ ROOT-РОЗДІЛУ
# ============================================================
create_root_partition() {
    info "Пошук вільного місця на диску..."
    local START
    START=$(sgdisk -F "$DISK") || \
        err "Не знайдено вільного місця. Потрібно мінімум ${MIN_ROOT_SIZE_GB} ГБ."

    info "Створення root-розділу від сектора $START до кінця диска..."
    sgdisk -n 0:"${START}":0 -t 0:8300 -c 0:"Arch Root" "$DISK"
    partprobe "$DISK"
    udevadm settle
    sleep 2

    ROOT_NUM=$(sgdisk -p "$DISK" | awk 'NR>2 && $1~/^[0-9]+$/ {last=$1} END{print last}')
    [[ -n "$ROOT_NUM" ]] || err "Не вдалося визначити номер нового розділу."

    if [[ "$DISK" =~ nvme ]]; then
        ROOT_PART="${DISK}p${ROOT_NUM}"
    else
        ROOT_PART="${DISK}${ROOT_NUM}"
    fi

    local SIZE_BYTES
    SIZE_BYTES=$(lsblk -b -d -n -o SIZE "$ROOT_PART" 2>/dev/null || echo 0)
    local SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
    info "Створено root: $ROOT_PART (${SIZE_GB} ГБ)"

    if [[ "$SIZE_GB" -lt "$MIN_ROOT_SIZE_GB" ]]; then
        sgdisk -d "$ROOT_NUM" "$DISK"
        err "Занадто мало місця (${SIZE_GB} ГБ). Потрібно мінімум ${MIN_ROOT_SIZE_GB} ГБ."
    fi
}

# ============================================================
#  5. ФОРМАТУВАННЯ ТА BTRFS SUBVOLUMES (з @swap!)
# ============================================================
setup_btrfs() {
    info "Форматування $ROOT_PART у btrfs..."
    mkfs.btrfs -f -L arch-root "$ROOT_PART"

    info "Створення subvolumes: @, @home, @var_log, @snapshots, @swap..."
    mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var_log
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@swap
    umount /mnt

    info "Монтування subvolumes..."
    mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt

    mkdir -p /mnt/{home,var/log,.snapshots,swap,boot/efi}

    mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
    mount -o noatime,compress=zstd,subvol=@var_log "$ROOT_PART" /mnt/var/log
    mount -o noatime,compress=zstd,subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
    mount -o noatime,subvol=@swap "$ROOT_PART" /mnt/swap
    mount "$EFI_PART" /mnt/boot/efi
}

# ============================================================
#  6. SWAPFILE (у @swap subvolume)
# ============================================================
create_swapfile() {
    info "Створення swapfile ${SWAP_SIZE} у @swap..."
    btrfs filesystem mkswapfile --size "$SWAP_SIZE" /mnt/swap/swapfile
    info "Активація swapfile..."
    swapon /mnt/swap/swapfile
    info "Swapfile створено та активовано: /swap/swapfile"
}

# ============================================================
#  7. ДЗЕРКАЛА
# ============================================================
setup_mirrors() {
    info "Встановлення reflector..."
    retry_forever pacman -Sy --noconfirm reflector

    info "Пошук найшвидших дзеркал (Ukraine, Germany)..."
    retry_forever reflector --country Ukraine,Germany --latest 15 \
        --protocol https --sort rate --save /etc/pacman.d/mirrorlist
}

# ============================================================
#  8. PACSTRAP
# ============================================================
pacstrap_base() {
    info "Pacstrap — встановлення бази..."
    retry_forever pacstrap /mnt base base-devel linux linux-firmware linux-headers \
        networkmanager vim nano git reflector btrfs-progs \
        grub efibootmgr os-prober \
        man-db man-pages bash-completion \
        curl wget sudo ntfs-3g
}

# ============================================================
#  9. FSTAB + КОПІЮВАННЯ MIRRORLIST
# ============================================================
generate_fstab() {
    info "Генерація fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

    info "Копіювання оптимізованого mirrorlist у встановлену систему..."
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

    warn "Згенерований fstab:"
    cat /mnt/etc/fstab
    echo ""
}

# ============================================================
#  10. CHROOT НАЛАШТУВАННЯ
# ============================================================
chroot_setup() {
    info "Підготовка скрипта налаштувань..."

    cat > /mnt/install-chroot.sh <<EOF
#!/bin/bash
set -e

# --- Очищення db.lck перед pacman ---
clean_db_lock() {
    [[ -f /var/lib/pacman/db.lck ]] && rm -f /var/lib/pacman/db.lck
}

# --- retry всередині chroot (ОДИН backslash перед \$!) ---
retry_forever() {
    local attempt=1
    while true; do
        clean_db_lock
        if "\$@" ; then
            return 0
        fi
        echo "[!] Спроба \$attempt не вдалася. Повтор через 5с..."
        sleep 5
        ((attempt++))
    done
}

# --- Час ---
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# --- Locale ---
echo "$LOCALE_EXTRA UTF-8" >> /etc/locale.gen
echo "$LOCALE_SYSTEM UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE_SYSTEM" > /etc/locale.conf

# --- Консоль ---
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# --- Hostname / Hosts ---
echo "$NEW_HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $NEW_HOSTNAME.localdomain $NEW_HOSTNAME
HOSTS

# --- Sudo ---
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# --- Користувач ---
useradd -m -G wheel,audio,video,storage,render -s /bin/bash $USERNAME

# ============================================
#  МІКРОКОД CPU (ПЕРЕД GRUB!)
# ============================================
if grep -q "GenuineIntel" /proc/cpuinfo; then
    retry_forever pacman -S --noconfirm intel-ucode
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    retry_forever pacman -S --noconfirm amd-ucode
fi

# --- mkinitcpio (GPU-залежно) ---
if [[ "$GPU" == "nvidia" ]]; then
    sed -i 's/^MODULES=(.*)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
fi

# --- Сервіси (без bluetooth — ще не встановлений!) ---
systemctl enable NetworkManager.service
systemctl enable fstrim.timer
systemctl enable reflector.timer

# --- Reflector config ---
mkdir -p /etc/xdg/reflector
cat > /etc/xdg/reflector/reflector.conf <<'REFL'
--country Ukraine,Germany
--latest 15
--protocol https
--sort rate
--save /etc/pacman.d/mirrorlist
REFL

# ============================================
#  GRUB (встановлюємо, але mkconfig ПІЗНІШЕ)
# ============================================
retry_forever pacman -S --noconfirm grub efibootmgr os-prober

# Надійний sed: додаємо/замінюємо параметри
if ! grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
    echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
else
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
fi

if ! grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
    echo 'GRUB_SAVEDEFAULT=true' >> /etc/default/grub
else
    sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub
fi

if ! grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
else
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
fi

if [[ "$GPU" == "nvidia" ]]; then
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/default/grub
    else
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet nvidia-drm.modeset=1 nvidia_drm.fbdev=1"' >> /etc/default/grub
    fi
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck

# --- Multilib (для lib32) ---
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
retry_forever pacman -Syu --noconfirm

# ============================================
#  GPU ДРАЙВЕРИ (з повним стеком Intel iGPU для гібриду)
# ============================================
if [[ "$GPU" == "nvidia" ]]; then
    retry_forever pacman -S --noconfirm nvidia-open-dkms nvidia-utils lib32-nvidia-utils \
        vulkan-icd-loader lib32-vulkan-icd-loader \
        nvidia-prime \
        intel-media-driver lib32-intel-media-driver \
        mesa lib32-mesa vulkan-intel lib32-vulkan-intel
elif [[ "$GPU" == "amd" ]]; then
    retry_forever pacman -S --noconfirm mesa xf86-video-amdgpu \
        vulkan-radeon lib32-vulkan-radeon \
        libva-mesa-driver lib32-libva-mesa-driver
elif [[ "$GPU" == "intel" ]]; then
    retry_forever pacman -S --noconfirm mesa xf86-video-intel \
        vulkan-intel lib32-vulkan-intel \
        intel-media-driver
fi

# --- Audio ---
retry_forever pacman -S --noconfirm pipewire pipewire-pulse pipewire-alsa wireplumber

# --- Bluetooth (СПОЧАТКУ пакет, ПОТІМ enable сервіс!) ---
retry_forever pacman -S --noconfirm bluez bluez-utils
systemctl enable bluetooth.service

# --- Додаткові пакети ---
retry_forever pacman -S --noconfirm $PACKAGES_EXTRA

# ============================================
#  INITRAMFS (з ucode + nvidia модулями)
# ============================================
mkinitcpio -P

# ============================================
#  GRUB MKCONFIG (ПІСЛЯ ВСЬОГО — щоб ucode потрапив!)
# ============================================
grub-mkconfig -o /boot/grub/grub.cfg
EOF

    chmod +x /mnt/install-chroot.sh
    info "Запуск налаштувань у chroot..."
    arch-chroot /mnt bash /install-chroot.sh
    rm -f /mnt/install-chroot.sh
}

# ============================================================
#  11. ПАРОЛІ
# ============================================================
set_passwords() {
    info "Встановлення паролів..."
    echo ""
    warn "Введи пароль для root (адміністратора):"
    arch-chroot /mnt passwd root

    echo ""
    warn "Введи пароль для $USERNAME:"
    arch-chroot /mnt passwd "$USERNAME"
}

# ============================================================
#  12. AUR HELPER (paru-bin)
# ============================================================
install_aur_helper() {
    local PARU_URL="https://aur.archlinux.org/paru-bin.git"

    info "Перевірка доступності AUR репозиторію paru-bin..."
    check_git_repo "$PARU_URL"

    info "Встановлення paru-bin з AUR..."

    cat > /mnt/install-paru.sh <<EOF
#!/bin/bash
set -e
pacman -S --noconfirm git
su $USERNAME -c 'mkdir -p /tmp/aur'

attempt=1
while true; do
    if su $USERNAME -c 'rm -rf /tmp/aur/paru-bin && git clone https://aur.archlinux.org/paru-bin.git /tmp/aur/paru-bin'; then
        break
    fi
    echo "[!] Git clone не вдався (спроба \$attempt). Повтор через 5с..."
    sleep 5
    ((attempt++))
done

cd /tmp/aur/paru-bin
su $USERNAME -c 'makepkg -si --noconfirm'
cd /
rm -rf /tmp/aur
EOF

    chmod +x /mnt/install-paru.sh
    arch-chroot /mnt bash /install-paru.sh
    rm -f /mnt/install-paru.sh
}

# ============================================================
#  13. ЗАВЕРШЕННЯ (з swapoff!)
# ============================================================
finish() {
    info "Вимкнення swap..."
    swapoff /mnt/swap/swapfile 2>/dev/null || true

    info "Синхронізація та розмонтування..."
    sync
    umount -R /mnt

    echo ""
    info "========================================"
    info "  Arch Linux встановлено успішно!"
    info "========================================"
    info "  Hostname : $NEW_HOSTNAME"
    info "  User     : $USERNAME"
    info "  Disk     : $DISK"
    info "  Root     : $ROOT_PART"
    info "  FS       : btrfs (@, @home, @var_log, @snapshots, @swap)"
    info "  Swap     : /swap/swapfile ($SWAP_SIZE)"
    info "  Boot     : $EFI_PART (Windows EFI, не чіпали)"
    info "  Bootloader: GRUB (знаходить Windows автоматично)"
    info "========================================"
    echo ""
    warn "Перезавантажитися зараз?"
    read -r -p "[y/N] " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        reboot
    else
        info "Перезавантаження відмінено. Запусти 'reboot' вручну."
    fi
}

# ============================================================
#  ГОЛОВНИЙ ПОТІК
# ============================================================
main() {
    check_root
    check_uefi
    check_secure_boot
    check_network
    ensure_host_git

    select_disk
    find_efi

    echo ""
    warn "Підсумок встановлення:"
    warn "  Диск : $DISK"
    warn "  EFI  : $EFI_PART (існуючий, не чіпаємо)"
    warn "  Root : буде створено у вільному місці (все місце)"
    warn "  Swap : swapfile $SWAP_SIZE у @swap subvolume"
    warn "  FS   : btrfs з subvolumes"
    warn "  GPU  : $GPU"
    echo ""
    read -r -p "Продовжити встановлення? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || err "Встановлення скасовано."

    clean_old_partitions
    create_root_partition
    setup_btrfs
    create_swapfile
    setup_mirrors
    pacstrap_base
    generate_fstab
    chroot_setup
    set_passwords
    install_aur_helper
    finish
}

main "$@"

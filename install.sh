#!/bin/bash

# ============================================================
#  НАЛАШТУВАННЯ — ЗМІНИ ТІЛЬКИ ТУТ
# ============================================================
DISK="/dev/sda"                       # Для nvme: /dev/nvme0n1
EFI_NUM="1"                           # Номер EFI-розділу (sda1 / nvme0n1p1)
SWAP_SIZE="8G"
HOSTNAME="observerexe-larptop"
USERNAME="observerexe"
TIMEZONE="Europe/Kyiv"

# ============================================================
#  1. ПЕРЕВІРКИ
# ============================================================
if [ "$(id -u)" != "0" ]; then echo "Потрібен root"; exit 1; fi
if [ ! -d /sys/firmware/efi/efivars ]; then echo "Потрібен UEFI"; exit 1; fi
curl -fsI https://archlinux.org >/dev/null 2>&1 || { echo "Немає інтернету"; exit 1; }

# ============================================================
#  2. РОЗБИВКА ДИСКА
# ============================================================
echo "[*] Очищення старих розділів 5,6 (якщо є)..."
sgdisk -d 5 "$DISK" 2>/dev/null || true
sgdisk -d 6 "$DISK" 2>/dev/null || true
partprobe "$DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || true

echo "[*] Створення root-розділу у вільному місці..."
START=$(sgdisk -F "$DISK")
sgdisk -n 0:"$START":0 -t 0:8300 -c 0:"Arch Root" "$DISK"
partprobe "$DISK"
sleep 2
udevadm settle

echo "[*] Визначення номеру нового розділу..."
ROOT_NUM=$(sgdisk -p "$DISK" | tail -1 | awk '{print $1}')
if echo "$DISK" | grep -q "nvme"; then
    ROOT_PART="${DISK}p${ROOT_NUM}"
    EFI_PART="${DISK}p${EFI_NUM}"
else
    ROOT_PART="${DISK}${ROOT_NUM}"
    EFI_PART="${DISK}${EFI_NUM}"
fi

SIZE_GB=$(lsblk -b -n -o SIZE "$ROOT_PART" | awk '{print int($1/1024/1024/1024)}')
if [ "$SIZE_GB" -lt 50 ]; then echo "Замало місця: ${SIZE_GB}G"; exit 1; fi
echo "[*] Root: $ROOT_PART (${SIZE_GB} ГБ)"

# ============================================================
#  3. ФОРМАТУВАННЯ
# ============================================================
echo "[*] Форматування $ROOT_PART у btrfs..."
mkfs.btrfs -f -L arch-root "$ROOT_PART"

# ============================================================
#  4. BTRFS SUBVOLUMES
# ============================================================
echo "[*] Створення subvolumes..."
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap
umount /mnt

echo "[*] Монтування..."
mount -o noatime,compress=zstd,subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/home /mnt/var/log /mnt/.snapshots /mnt/swap /mnt/boot/efi
mount -o noatime,compress=zstd,subvol=@home "$ROOT_PART" /mnt/home
mount -o noatime,compress=zstd,subvol=@var_log "$ROOT_PART" /mnt/var/log
mount -o noatime,compress=zstd,subvol=@snapshots "$ROOT_PART" /mnt/.snapshots
mount -o noatime,subvol=@swap "$ROOT_PART" /mnt/swap
mount "$EFI_PART" /mnt/boot/efi

# ============================================================
#  5. SWAPFILE
# ============================================================
echo "[*] Створення swapfile..."
btrfs filesystem mkswapfile --size "$SWAP_SIZE" /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# ============================================================
#  6. ДЗЕРКАЛА
# ============================================================
echo "[*] Оновлення дзеркал..."
pacman -Sy --noconfirm reflector || true
reflector --country Ukraine,Germany --latest 15 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# ============================================================
#  7. PACSTRAP (з retry)
# ============================================================
echo "[*] Встановлення базової системи..."
while true; do
    pacstrap /mnt base base-devel linux linux-firmware linux-headers \
        networkmanager vim nano git reflector btrfs-progs \
        grub efibootmgr os-prober man-db man-pages bash-completion \
        curl wget sudo ntfs-3g && break
    echo "[!] Pacstrap не вдався, повтор через 5с..."
    sleep 5
done

# ============================================================
#  8. FSTAB
# ============================================================
echo "[*] Генерація fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# ============================================================
#  9. CHROOT КОМАНДИ (лінійно, одна за одною)
# ============================================================

echo "[*] Часовий пояс..."
arch-chroot /mnt /bin/bash -c "ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime"
arch-chroot /mnt /bin/bash -c "hwclock --systohc"

echo "[*] Locale..."
arch-chroot /mnt /bin/bash -c "echo 'uk_UA.UTF-8 UTF-8' >> /etc/locale.gen"
arch-chroot /mnt /bin/bash -c "echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen"
arch-chroot /mnt /bin/bash -c "locale-gen"
arch-chroot /mnt /bin/bash -c "echo 'LANG=en_US.UTF-8' > /etc/locale.conf"

echo "[*] Клавіатура..."
arch-chroot /mnt /bin/bash -c "echo 'KEYMAP=us' > /etc/vconsole.conf"

echo "[*] Hostname..."
arch-chroot /mnt /bin/bash -c "echo '$HOSTNAME' > /etc/hostname"
arch-chroot /mnt /bin/bash -c "echo '127.0.0.1   localhost' > /etc/hosts"
arch-chroot /mnt /bin/bash -c "echo '::1         localhost' >> /etc/hosts"
arch-chroot /mnt /bin/bash -c "echo '127.0.1.1   $HOSTNAME.localdomain $HOSTNAME' >> /etc/hosts"

echo "[*] Sudo..."
arch-chroot /mnt /bin/bash -c "echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel"
arch-chroot /mnt /bin/bash -c "chmod 440 /etc/sudoers.d/wheel"

echo "[*] Користувач..."
arch-chroot /mnt /bin/bash -c "useradd -m -G wheel,audio,video,storage,render -s /bin/bash $USERNAME"

echo "[*] CPU microcode..."
if grep -q "GenuineIntel" /proc/cpuinfo; then
    while true; do
        arch-chroot /mnt /bin/bash -c "pacman -S --noconfirm intel-ucode" && break
        echo "[!] Повтор intel-ucode через 5с..."
        sleep 5
    done
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    while true; do
        arch-chroot /mnt /bin/bash -c "pacman -S --noconfirm amd-ucode" && break
        echo "[!] Повтор amd-ucode через 5с..."
        sleep 5
    done
fi

echo "[*] mkinitcpio NVIDIA..."
arch-chroot /mnt /bin/bash -c 'sed -i "s/^MODULES=(.*)/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/" /etc/mkinitcpio.conf'

echo "[*] Сервіси..."
arch-chroot /mnt /bin/bash -c "systemctl enable NetworkManager.service"
arch-chroot /mnt /bin/bash -c "systemctl enable fstrim.timer"
arch-chroot /mnt /bin/bash -c "systemctl enable reflector.timer"

echo "[*] Reflector config..."
arch-chroot /mnt /bin/bash -c "mkdir -p /etc/xdg/reflector"
arch-chroot /mnt /bin/bash -c "echo '--country Ukraine,Germany' > /etc/xdg/reflector/reflector.conf"
arch-chroot /mnt /bin/bash -c "echo '--latest 15' >> /etc/xdg/reflector/reflector.conf"
arch-chroot /mnt /bin/bash -c "echo '--protocol https' >> /etc/xdg/reflector/reflector.conf"
arch-chroot /mnt /bin/bash -c "echo '--sort rate' >> /etc/xdg/reflector/reflector.conf"
arch-chroot /mnt /bin/bash -c "echo '--save /etc/pacman.d/mirrorlist' >> /etc/xdg/reflector/reflector.conf"

echo "[*] GRUB встановлення..."
while true; do
    arch-chroot /mnt /bin/bash -c "pacman -S --noconfirm grub efibootmgr os-prober" && break
    echo "[!] Повтор grub через 5с..."
    sleep 5
done

echo "[*] GRUB налаштування..."
arch-chroot /mnt /bin/bash -c 'grep -q "^GRUB_DEFAULT=" /etc/default/grub || echo "GRUB_DEFAULT=saved" >> /etc/default/grub'
arch-chroot /mnt /bin/bash -c 'sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/" /etc/default/grub'
arch-chroot /mnt /bin/bash -c 'grep -q "^GRUB_SAVEDEFAULT=" /etc/default/grub || echo "GRUB_SAVEDEFAULT=true" >> /etc/default/grub'
arch-chroot /mnt /bin/bash -c 'sed -i "s/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/" /etc/default/grub'
arch-chroot /mnt /bin/bash -c 'grep -q "^GRUB_DISABLE_OS_PROBER=" /etc/default/grub || echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub'
arch-chroot /mnt /bin/bash -c 'sed -i "s/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/" /etc/default/grub'

echo "[*] NVIDIA kernel params..."
arch-chroot /mnt /bin/bash -c 'if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" /etc/default/grub; then sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 nvidia-drm.modeset=1 nvidia_drm.fbdev=1\"/" /etc/default/grub; else echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet nvidia-drm.modeset=1 nvidia_drm.fbdev=1\"" >> /etc/default/grub; fi'

echo "[*] GRUB install..."
arch-chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck"

echo "[*] Multilib..."
arch-chroot /mnt /bin/bash -c 'sed -i "/\\[multilib\\]/,/Include/s/^#//" /etc/pacman.conf'

echo "[*] Оновлення бази (pacman -Syu)..."
while true; do
    arch-chroot /mnt /bin/bash -c "pacman -Syu --noconfirm" && break
    echo "[!] Повтор pacman -Syu через 5с..."
    sleep 5
done

echo "[*] GPU драйвери..."
while true; do
    arch-chroot /mnt /bin/bash -c "pacman -S --noconfirm nvidia-open-dkms nvidia-utils lib32-nvidia-utils vulkan-icd-loader lib32-vulkan-icd-loader nvidia-prime intel-media-driver mesa lib32-mesa vulkan-intel lib32-vulkan-intel" && break
    echo "[!] Повтор GPU drivers через 5с..."
    sleep 5
done

echo "[*] Audio..."
while true; do
    arch-chroot /mnt /bin/bash -c "pacman -S --noconfirm pipewire pipewire-pulse pipewire-alsa wireplumber" && break
    echo "[!] Повтор audio через 5с..."
    sleep 5
done

echo "[*] Bluetooth..."
while true; do
    arch-chroot /mnt /bin/bash -c "pacman -S --noconfirm bluez bluez-utils" && break
    echo "[!] Повтор bluetooth через 5с..."
    sleep 5
done
arch-chroot /mnt /bin/bash -c "systemctl enable bluetooth.service"

echo "[*] Додаткові пакети..."
while true; do
    arch-chroot /mnt /bin/bash -c "pacman -S --noconfirm fastfetch firefox btop cmatrix cava" && break
    echo "[!] Повтор extra packages через 5с..."
    sleep 5
done

echo "[*] Initramfs..."
arch-chroot /mnt /bin/bash -c "mkinitcpio -P"

echo "[*] GRUB mkconfig..."
arch-chroot /mnt /bin/bash -c "grub-mkconfig -o /boot/grub/grub.cfg"

# ============================================================
#  10. ПАРОЛІ
# ============================================================
echo ""
echo "Введи пароль для root:"
arch-chroot /mnt passwd root

echo ""
echo "Введи пароль для $USERNAME:"
arch-chroot /mnt passwd "$USERNAME"

# ============================================================
#  11. PARU
# ============================================================
echo "[*] Встановлення paru-bin..."
arch-chroot /mnt /bin/bash -c "pacman -S --noconfirm git"
arch-chroot /mnt /bin/bash -c "mkdir -p /tmp/aur"
arch-chroot /mnt /bin/su - "$USERNAME" -c "cd /tmp/aur && rm -rf paru-bin && git clone https://aur.archlinux.org/paru-bin.git"
arch-chroot /mnt /bin/su - "$USERNAME" -c "cd /tmp/aur/paru-bin && makepkg -si --noconfirm"

# ============================================================
#  12. ЗАВЕРШЕННЯ
# ============================================================
echo "[*] Вимкнення swap..."
swapoff /mnt/swap/swapfile 2>/dev/null || true

echo "[*] Синхронізація..."
sync

echo "[*] Розмонтування..."
umount -R /mnt

echo ""
echo "========================================"
echo "  Arch Linux встановлено успішно!"
echo "========================================"
echo "  Hostname : $HOSTNAME"
echo "  User     : $USERNAME"
echo "  Disk     : $DISK"
echo "  Root     : $ROOT_PART"
echo "  FS       : btrfs з subvolumes"
echo "  Swap     : /swap/swapfile ($SWAP_SIZE)"
echo "========================================"
echo ""
echo "Перезавантажитися зараз? [y/N]"
read -r yn
if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
    reboot
fi

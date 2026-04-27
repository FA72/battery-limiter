# qcom_pmi8998_charger DKMS Fix

Ready-to-use DKMS override for OnePlus 6 / Mobian / `sdm845` devices that use
the `qcom_pmi8998_charger` driver.

## What it fixes

1. Wake-IRQ leak on driver unbind.
   Without the fix, re-binding the charger driver can fail with `-EEXIST`, so
   the charger IC cannot be cleanly re-probed from userspace.
2. PMI8998 safety-timer latch (`SFT_EXPIRE`).
   Long low-current charging sessions can latch the charger into
   `Not charging` until a fresh `CHARGING_ENABLE_CMD` edge is generated.

The public repo intentionally keeps only the final deployment set:

- `dkms/` with the patched driver source
- `install_dkms.sh`
- `uninstall_dkms.sh`
- `verify_after_reboot.sh`

Temporary diagnostics, one-off manual install helpers, and mail-ready upstream
patch files are intentionally not included here.

## Install

From Windows:

```powershell
scp -r .\kernel-patch oneplus6-admin:~/kpatch
ssh oneplus6-admin 'sudo bash ~/kpatch/install_dkms.sh'
```

What `install_dkms.sh` does:

1. Installs DKMS and kernel build dependencies if needed.
2. Backs up the currently resolved `qcom_pmi8998_charger.ko` into
   `/var/backups/kpatch/`.
3. Registers DKMS package `qcom-pmi8998-wakeirq-fix/1.1`.
4. Removes older package revisions automatically.
5. Builds and installs the patched module into
   `/lib/modules/$(uname -r)/updates/dkms/`.
6. Regenerates initramfs and runs Mobian's `zz-qcom-bootimg` hook so the fix
   survives reboot and future kernel updates.

## Activate

Safest path:

```powershell
ssh oneplus6-admin 'sudo systemctl reboot'
```

Optional no-reboot path if you want the new module immediately:

```powershell
ssh oneplus6-admin 'sudo rmmod qcom_pmi8998_charger; sudo modprobe qcom_pmi8998_charger'
```

The platform device should auto-bind again after `modprobe`.

## Verify

```powershell
ssh oneplus6-admin 'bash ~/kpatch/verify_after_reboot.sh'
```

Optional direct checks:

```powershell
ssh oneplus6-admin "modinfo -n qcom_pmi8998_charger"
ssh oneplus6-admin "sudo grep -E '^(1007|10a0):' /sys/kernel/debug/regmap/0-02/registers"
ssh oneplus6-admin "cat /sys/class/power_supply/pmi8998-charger/status"
```

Expected steady-state result:

- the loaded module resolves from `.../updates/dkms/...`
- register `10a0` is `00` (safety timers disabled)
- `1007` does not have `SFT_EXPIRE` set
- charger status returns to `Charging` when external power is present

## Uninstall

```powershell
ssh oneplus6-admin 'sudo bash ~/kpatch/uninstall_dkms.sh'
ssh oneplus6-admin 'sudo systemctl reboot'
```

`uninstall_dkms.sh` removes all registered versions of
`qcom-pmi8998-wakeirq-fix`, regenerates initramfs, and re-runs the Mobian boot
image hook so the stock module becomes active again after reboot.

---

## По-русски

Это готовый DKMS-override для OnePlus 6 / Mobian / `sdm845`, где используется
драйвер `qcom_pmi8998_charger`.

### Что исправлено

1. Утечка wake-IRQ при `unbind` драйвера.
   Без этого повторный `bind` иногда падает с `-EEXIST`, и charger IC нельзя
   нормально переподнять из userspace.
2. Защёлка safety-таймера PMI8998 (`SFT_EXPIRE`).
   При длинной зарядке малым током драйвер мог залипнуть в `Not charging`,
   пока не будет сгенерирован новый `CHARGING_ENABLE_CMD` edge.

В публичной репе оставлен только финальный набор:

- `dkms/` с исходником патченного драйвера
- `install_dkms.sh`
- `uninstall_dkms.sh`
- `verify_after_reboot.sh`

Диагностические скрипты, одноразовые helper'ы для ручной установки и файлы для
upstream-рассылки патчей сюда специально не включены.

### Установка

С Windows:

```powershell
scp -r .\kernel-patch oneplus6-admin:~/kpatch
ssh oneplus6-admin 'sudo bash ~/kpatch/install_dkms.sh'
```

Что делает `install_dkms.sh`:

1. Ставит DKMS и зависимости для сборки, если их нет.
2. Снимает бэкап текущего `qcom_pmi8998_charger.ko` в `/var/backups/kpatch/`.
3. Регистрирует пакет `qcom-pmi8998-wakeirq-fix/1.1`.
4. Автоматически удаляет старые ревизии пакета.
5. Собирает и ставит патченный модуль в
   `/lib/modules/$(uname -r)/updates/dkms/`.
6. Пересобирает initramfs и запускает Mobian-хук `zz-qcom-bootimg`, чтобы
   фикс переживал ребуты и апдейты ядра.

### Активация

Самый простой и безопасный путь:

```powershell
ssh oneplus6-admin 'sudo systemctl reboot'
```

Необязательный вариант без ребута:

```powershell
ssh oneplus6-admin 'sudo rmmod qcom_pmi8998_charger; sudo modprobe qcom_pmi8998_charger'
```

После `modprobe` платформенное устройство должно автоматически привязаться
обратно.

### Проверка

```powershell
ssh oneplus6-admin 'bash ~/kpatch/verify_after_reboot.sh'
```

Дополнительно можно проверить вручную:

```powershell
ssh oneplus6-admin "modinfo -n qcom_pmi8998_charger"
ssh oneplus6-admin "sudo grep -E '^(1007|10a0):' /sys/kernel/debug/regmap/0-02/registers"
ssh oneplus6-admin "cat /sys/class/power_supply/pmi8998-charger/status"
```

Что ожидается в норме:

- модуль берётся из `.../updates/dkms/...`
- `10a0 = 00` (safety-таймеры выключены)
- в `1007` не стоит `SFT_EXPIRE`
- при подключённом питании статус возвращается в `Charging`

### Удаление

```powershell
ssh oneplus6-admin 'sudo bash ~/kpatch/uninstall_dkms.sh'
ssh oneplus6-admin 'sudo systemctl reboot'
```

`uninstall_dkms.sh` удаляет все зарегистрированные версии
`qcom-pmi8998-wakeirq-fix`, пересобирает initramfs и заново вызывает Mobian-
хук для boot image, чтобы после ребута снова активировался штатный модуль.
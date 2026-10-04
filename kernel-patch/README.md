# qcom_pmi8998_charger DKMS override

## Русский

Патч для драйвера `qcom_pmi8998_charger` на OnePlus 6 / Mobian / `sdm845`.
Пакет `qcom-pmi8998-wakeirq-fix/1.1` содержит две разные доработки:

1. Освобождает wake-IRQ при снятии драйвера. Это устраняет наблюдавшуюся
   ошибку `-EEXIST` при повторном `bind`.
2. Выключает аппаратные таймеры предварительного и основного заряда PMI8998,
   а при `probe` создаёт переход `0 -> 1` в `CHARGING_ENABLE_CMD`, чтобы
   сбросить защёлку `SFT_EXPIRE` после долгой зарядки малым током.

Второй пункт меняет аппаратную политику защиты, а не только исправляет
утечку ресурса. Температурные проверки и диапазон заряда в Bash не заменяют
аппаратные safety-таймеры и не гарантируют безопасность батареи. Этот override
описан для конкретного устройства; перенос на другой телефон или ядро требует
отдельной проверки совместимости. Будущая сборка DKMS тоже может потребовать
адаптации исходника к новому API ядра.

### Установка и активация

Используйте SSH-профиль своего устройства (`your-device` ниже). До установки
должен быть доступен локальный терминал или другой способ восстановления.
Установщик меняет пакеты, модули, initramfs и, при наличии Mobian-хука,
Android boot partition:

```powershell
scp -r .\kernel-patch your-device:~/kpatch
ssh your-device 'sudo bash ~/kpatch/install_dkms.sh'
ssh your-device 'sudo systemctl reboot'
```

`install_dkms.sh` сохраняет текущий файл модуля в `/var/backups/kpatch/`,
ставит DKMS и зависимости, регистрирует версию `1.1` и удаляет прежние версии
этого пакета. Затем собирает override в `/lib/modules/$(uname -r)/updates/`,
пересобирает initramfs и вызывает `zz-qcom-bootimg`, если он установлен.
`AUTOINSTALL=yes` запрашивает пересборку при обновлении ядра; успешную сборку
и загрузку после обновления всё равно нужно проверять.

### Проверка

По умолчанию проверка только читает состояние: она не пишет в sysfs и не
перепривязывает драйвер.

```powershell
ssh your-device 'bash ~/kpatch/verify_after_reboot.sh'
ssh your-device 'dkms status; modinfo -n qcom_pmi8998_charger'
```

`modinfo -n` показывает установленный файл, но сам по себе не доказывает,
что именно он загружен. Скрипт дополнительно ищет символ
`smb2_disable_wake_irq` в работающем ядре. Проверка символа требует `sudo`.
При подключённом питании статус может быть `Discharging` или `Not charging`,
если лимитер намеренно остановил заряд: отсутствие `Charging` само по себе
не означает неисправность.

Регистр `10a0` и защёлку `SFT_EXPIRE` можно прочитать отдельно, если debugfs
уже доступен на этом ядре:

```powershell
ssh your-device "sudo grep -E '^(1007|10a0):' /sys/kernel/debug/regmap/0-02/registers"
```

Нулевые биты `0` и `1` в `10a0` означают отключённые safety-таймеры; отсутствие
бита `6` в `1007` означает, что `SFT_EXPIRE` не установлен в момент чтения.
Пути debugfs относятся к этому устройству.

Проверка повторного `unbind/bind` выделена в отдельный явный режим, который
меняет состояние PMIC и может затронуть его дочерние устройства. Запускайте
его только при проверенном драйвере и доступном восстановлении:

```powershell
ssh your-device 'bash ~/kpatch/verify_after_reboot.sh --exercise-rebind'
```

### Удаление

```powershell
ssh your-device 'sudo bash ~/kpatch/uninstall_dkms.sh'
ssh your-device 'sudo systemctl reboot'
```

Скрипт удаляет зарегистрированные версии `qcom-pmi8998-wakeirq-fix`,
пересобирает initramfs и повторно вызывает Mobian-хук. После перезагрузки
проверьте, что `modinfo` выбирает штатный модуль.

## English

This device-specific override for OnePlus 6 / Mobian / `sdm845` has two changes:
release the wake IRQ on driver removal, and disable both PMI8998 charge safety
timers while generating a fresh `CHARGING_ENABLE_CMD` edge during probe to clear
`SFT_EXPIRE`. The second change alters hardware protection policy. Userspace
SoC and temperature checks are not replacements for hardware safety timers and
do not establish battery safety on another device.

Use your own SSH profile and keep a recovery route before installation:

```powershell
scp -r .\kernel-patch your-device:~/kpatch
ssh your-device 'sudo bash ~/kpatch/install_dkms.sh'
ssh your-device 'sudo systemctl reboot'
ssh your-device 'bash ~/kpatch/verify_after_reboot.sh'
```

The installer backs up the resolved module, installs build dependencies,
registers `qcom-pmi8998-wakeirq-fix/1.1`, removes earlier package versions,
builds into `updates/`, regenerates initramfs and invokes Mobian's boot image
hook if present. DKMS requests rebuilds for future kernels; compatibility and
successful loading still need verification after each upgrade.

`verify_after_reboot.sh` is read-only by default. It checks the installed module
path, the loaded module, the fix symbol in the running kernel (using `sudo`),
and charger sysfs state. `modinfo -n` alone reports the installed file, not the
loaded file. A paused limiter may legitimately report `Discharging` or
`Not charging` with external power present.

The explicit `--exercise-rebind` option also unbinds and binds the SPMI parent.
It changes PMIC device state and can affect sibling devices; use it only with
a verified driver and a recovery route. Register checks and uninstall commands
are shown in the Russian instructions above. Removing the DKMS package and
rebooting returns to the distribution module.

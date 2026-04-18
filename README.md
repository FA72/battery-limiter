# Battery Limiter

## English

Ready-to-publish package for Linux devices with `systemd` that expose:
- a reliable battery gauge with `capacity`, `temp`, `status`, `current_now`;
- a writable charger driver node `current_max`.

The package auto-detects the first power_supply node that exposes `capacity`, `temp`, `status`, and `current_now` together unless you override these paths explicitly.
The package auto-detects the first available `/sys/class/power_supply/*/current_max` node unless you override it explicitly.

The limiter keeps the battery in the 40%-80% range and uses a simple state machine:
- `monitor` reads state without touching `current_max` while the battery stays in range;
- `charge_recovery` tries to wake charging with a ladder `0 -> 500mA -> ... -> 1A -> driver control`;
- `charge_tuning` finds the lowest limit that still keeps `Charging`;
- `pause_recovery` forces `Discharging` by writing `0`;
- `temp_lock` blocks charging while the device is too hot.

### Package contents

- `battery-limiter.sh` — main limiter script.
- `battery-limiter.service` — `systemd` unit.
- `journald-battery-limiter.conf` — persistent journal retention config.
- `setup_battery_limiter.ps1` — deployment script over SSH.
- `battery-limiter.env.example` — example override file for device-specific settings.

### Deployment

1. If needed, copy `battery-limiter.env.example` to `battery-limiter.env` and adjust the values for your device.
2. Open PowerShell in this directory.
3. Run the deployment script with explicit SSH parameters:

```powershell
.\setup_battery_limiter.ps1 `
  -SshHost your-device-ip `
  -SshUser your-user `
  -SshKey "$env:USERPROFILE\.ssh\your_private_key"
```

You can also provide the same values via environment variables:
- `BATTERY_LIMITER_SSH_HOST`
- `BATTERY_LIMITER_SSH_USER`
- `BATTERY_LIMITER_SSH_KEY`

The deployment script:
- uploads `battery-limiter.sh` to `/usr/local/bin/`;
- uploads `battery-limiter.service` to `/etc/systemd/system/`;
- uploads `journald-battery-limiter.conf` to `/etc/systemd/journald.conf.d/`;
- optionally uploads `battery-limiter.env` to `/etc/default/battery-limiter`;
- runs `daemon-reload`, restarts `systemd-journald`, enables and restarts the service.

### Verification

```bash
systemctl status battery-limiter.service
journalctl -u battery-limiter.service -f
cat /sys/class/power_supply/<battery-node>/status
cat /sys/class/power_supply/<battery-node>/current_now
find /sys/class/power_supply -name capacity
find /sys/class/power_supply -name current_max
```

### What may differ on other devices

1. Sysfs paths. Another phone will likely use different battery and charger nodes. The script auto-detects the first battery gauge node that exposes `capacity`, `temp`, `status`, and `current_now` together, and also auto-detects the first available `current_max` node. If that is not enough, override `BATTERY_GAUGE_BASE_PATH`, `SYS_CAP`, `SYS_TEMP`, `SYS_BQST`, `SYS_CUR`, `SYS_CMAX`, and `CHARGER_CURRENT_MAX_PATH` in `battery-limiter.env`.
2. Driver maximum current. `CURRENT_DRIVER` and `STOP_CURRENT_MAX` are still device-specific. The example value `4800000` is valid for one specific charger driver; another device may require a different ceiling.
3. Thresholds and timings. `CAP_LOW`, `CAP_HIGH`, thermal thresholds, and retry timings may need adjustment.
4. Charging model. This package assumes charging can be influenced through `current_max`. If your driver uses another control model, adapt the script logic, not only the paths.
5. Init system. The package is built for `systemd`. Other init systems will require a different service wrapper.

### Notes

- The script waits for required sysfs nodes instead of failing immediately.
- `ExecStopPost` returns charger control to the driver when the service stops.

---

## Русский

Готовый пакет для Linux-устройств с `systemd`, у которых есть:
- надёжный battery gauge с `capacity`, `temp`, `status`, `current_now`;
- writable-узел зарядного драйвера `current_max`.

Пакет автоматически находит первый power_supply node, в котором одновременно есть `capacity`, `temp`, `status` и `current_now`, если эти пути не заданы явно.
Пакет автоматически находит первый доступный узел `/sys/class/power_supply/*/current_max`, если путь не задан явно через override.

Пакет удерживает заряд в диапазоне 40%-80% и использует простую state machine:
- `monitor` наблюдает за состоянием и не пишет в `current_max`, пока заряд в диапазоне;
- `charge_recovery` пытается вернуть зарядку через лестницу `0 -> 500mA -> ... -> 1A -> driver control`;
- `charge_tuning` подбирает минимальный лимит, который удерживает `Charging`;
- `pause_recovery` принудительно переводит устройство в `Discharging` записью `0`;
- `temp_lock` запрещает зарядку при перегреве.

### Состав пакета

- `battery-limiter.sh` — основной скрипт лимитера.
- `battery-limiter.service` — unit для `systemd`.
- `journald-battery-limiter.conf` — конфигурация хранения логов в persistent journal.
- `setup_battery_limiter.ps1` — скрипт деплоя по SSH.
- `battery-limiter.env.example` — пример override-файла для параметров конкретного устройства.

### Деплой

1. При необходимости скопируйте `battery-limiter.env.example` в `battery-limiter.env` и измените значения под своё устройство.
2. Откройте PowerShell в этой папке.
3. Запустите deploy-скрипт с явными SSH-параметрами:

```powershell
.\setup_battery_limiter.ps1 `
  -SshHost your-device-ip `
  -SshUser your-user `
  -SshKey "$env:USERPROFILE\.ssh\your_private_key"
```

Те же значения можно передать через переменные окружения:
- `BATTERY_LIMITER_SSH_HOST`
- `BATTERY_LIMITER_SSH_USER`
- `BATTERY_LIMITER_SSH_KEY`

Скрипт деплоя:
- копирует `battery-limiter.sh` в `/usr/local/bin/`;
- копирует `battery-limiter.service` в `/etc/systemd/system/`;
- копирует `journald-battery-limiter.conf` в `/etc/systemd/journald.conf.d/`;
- при наличии копирует `battery-limiter.env` в `/etc/default/battery-limiter`;
- выполняет `daemon-reload`, перезапускает `systemd-journald`, включает и перезапускает сервис.

### Проверка после деплоя

```bash
systemctl status battery-limiter.service
journalctl -u battery-limiter.service -f
cat /sys/class/power_supply/<battery-node>/status
cat /sys/class/power_supply/<battery-node>/current_now
find /sys/class/power_supply -name capacity
find /sys/class/power_supply -name current_max
```

### Что может отличаться на других устройствах

1. Sysfs-пути. На другом телефоне почти наверняка будут другие battery и charger nodes. Скрипт сам пытается найти первый battery gauge node, где одновременно есть `capacity`, `temp`, `status` и `current_now`, а также первый доступный `current_max`. Если этого недостаточно, можно явно переопределить `BATTERY_GAUGE_BASE_PATH`, `SYS_CAP`, `SYS_TEMP`, `SYS_BQST`, `SYS_CUR`, `SYS_CMAX` и `CHARGER_CURRENT_MAX_PATH` через `battery-limiter.env`.
2. Максимальный ток драйвера. `CURRENT_DRIVER` и `STOP_CURRENT_MAX` всё ещё зависят от конкретного устройства. Пример `4800000` подходит для одного конкретного драйвера; на другом железе верхняя граница может быть другой.
3. Пороговые значения и интервалы. `CAP_LOW`, `CAP_HIGH`, температурные пороги и тайминги ретраев могут потребовать подстройки.
4. Модель управления зарядкой. Пакет рассчитан на драйвер, которым можно управлять через `current_max`. Если у драйвера другая модель управления, адаптировать нужно логику скрипта, а не только пути.
5. Init-система. Пакет ориентирован на `systemd`. Для других init-систем нужен другой service wrapper.

### Практические замечания

- Скрипт ждёт появления нужных sysfs-узлов при старте, а не падает сразу.
- `ExecStopPost` возвращает управление зарядкой драйверу при остановке сервиса.

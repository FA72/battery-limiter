# Battery Limiter

## Русский

Управление зарядкой OnePlus 6 с Mobian, который работает как домашний сервер.
Скрипт запускается через `systemd`, читает состояние батареи из Linux sysfs и
задаёт лимит входного тока зарядного контроллера через `current_max`. Приложение
для мониторинга — отдельный [MobianWebMonitor](https://github.com/FA72/MobianWebMonitor).

Это код для конкретного эксперимента, а не универсальная система защиты
аккумулятора. На другом устройстве нужно проверить драйвер, единицы измерения,
действие записи `0` и допустимые значения тока. Ограничение заряда и проверка
температуры не гарантируют безопасность батареи.

### Как это работает

Состояния публичной версии скрипта:

- `monitor` — читает заряд, температуру, статус и ток каждые 5 минут;
- `charge_recovery` — при заряде ниже `CAP_LOW` пытается восстановить `Charging`
  последовательностью `0 -> RECOVERY_PRIME -> 0 -> RECOVERY_BOOST`, затем
  перебирает ступени лимита тока;
- `charge_tuning` — начинает с 0,5 А, ждёт стабилизации статуса и при необходимости
  повышает лимит на 0,1 А до 1 А; если этого недостаточно, задаёт `CURRENT_DRIVER`;
- `pause_recovery` — при заряде выше `CAP_HIGH` пишет `0` до появления
  `Discharging`;
- `temp_lock` — при 45 °C блокирует зарядку и снимается после охлаждения ниже
  40 °C. Эта проверка выполняется в основном цикле, а не отдельным watchdog.

Диапазон по умолчанию — 40–80 %. При ровно 40 или 80 % срабатывает правило
«в диапазоне», поскольку условия в коде — строго ниже и строго выше порога.
Значение `current_max` — лимит входного тока, а не измеренный ток в аккумуляторе:
часть питания потребляет само устройство. Значение `4800000` относится к
конкретному драйверу и не означает постоянную зарядку батареи током 4,8 А.

### Почему начальный ток теперь 0,6 А

Фиксированного лимита 0,5 А стало не хватать после роста нагрузки контейнеров:
статус переключался между `Charging` и `Discharging`. 10 августа 2026 года
в профиле OnePlus 6 начальный лимит подняли до 0,6 А. Проверка работающего
сервера 4 октября 2026 года подтвердила `CURRENT_START=600000`. Это значение
сохранено в `battery-limiter.env.example`; без override скрипт по-прежнему
начинает с 0,5 А.
Дальше `charge_tuning` проверяет статус и при необходимости повышает лимит
ступенями до 1 А. Если статус `Charging` удалось удержать, дальнейшего повышения
в этом цикле не происходит.

Подстройка выполняется в сценарии низкого заряда. Внутри диапазона `monitor`
не меняет лимит: это подбор по фактическому статусу при запуске зарядки, а не
непрерывное измерение мощности нагрузки. Пример воспроизводит настройку
конкретного устройства; он не является выгрузкой текущих параметров сервера.

При неудачных циклах recovery скрипт также может перепривязать драйвер, причём
предпочитает родительское устройство SPMI. Это меняет состояние PMIC и может
затронуть его дочерние устройства. Для OnePlus 6 связанную доработку драйвера
и её ограничения см. в [kernel-patch/README.md](kernel-patch/README.md).

### Файлы

| Файл | Назначение |
| --- | --- |
| `battery-limiter.sh` | Логика лимитера |
| `battery-limiter.service` | Unit `systemd` |
| `battery-limiter.env.example` | Пример параметров без данных конкретного сервера |
| `setup_battery_limiter.ps1` | Установка через SSH из PowerShell |
| `journald-battery-limiter.conf` | Настройки постоянного системного журнала |
| `kernel-patch/` | DKMS override для `qcom_pmi8998_charger` |

Рабочий `battery-limiter.env` исключён из Git. SSH-ключи в репозиторий не входят.

### Настройка и установка

1. Скопируйте `battery-limiter.env.example` в `battery-limiter.env` и настройте
   параметры своего устройства.
2. Если power_supply-узлов несколько, задайте пути явно. Автопоиск выбирает
   первый узел с `capacity`, `temp`, `status`, `current_now` и первый
   `current_max`; это не проверка того, что выбраны нужные датчик и контроллер.
3. Из каталога репозитория запустите:

```powershell
.\setup_battery_limiter.ps1 `
  -SshHost your-device-ip `
  -SshUser your-user `
  -SshKey "$env:USERPROFILE\.ssh\your_private_key"
```

Вместо аргументов можно задать `BATTERY_LIMITER_SSH_HOST`,
`BATTERY_LIMITER_SSH_USER`, `BATTERY_LIMITER_SSH_KEY`.

Скрипт копирует лимитер в `/usr/local/bin/`, unit в `/etc/systemd/system/`,
настройки журнала в `/etc/systemd/journald.conf.d/`, а рабочий файл параметров,
если он есть, — в `/etc/default/battery-limiter`. Затем выполняет
`daemon-reload`, перезапускает `systemd-journald`, включает и перезапускает
лимитер. Это установка с изменением системы, а не диагностическая команда.
Патч ядра этим скриптом не устанавливается.

При остановке сервиса `ExecStopPost` записывает `STOP_CURRENT_MAX`
(по умолчанию `CURRENT_DRIVER`) и снимает установленное сервисом ограничение.
Остановка сервиса поэтому не означает отключение зарядки.

### Проверка без изменения зарядки

```bash
systemctl status battery-limiter.service --no-pager
journalctl -u battery-limiter.service -n 60 --no-pager
cat /sys/class/power_supply/<battery-node>/{capacity,temp,status,current_now}
cat /sys/class/power_supply/<charger-node>/current_max
```

В логах есть состояния, причины изменения лимита и показания датчиков.
Температура sysfs указана в десятых долях градуса, ток — в микроамперах;
проверьте эти единицы для своего драйвера.

Для локальной проверки синтаксиса без запуска лимитера:

```bash
bash -n battery-limiter.sh
bash -n kernel-patch/install_dkms.sh
bash -n kernel-patch/uninstall_dkms.sh
bash -n kernel-patch/verify_after_reboot.sh
bash tests/smoke.sh
```

`kernel-patch/verify_after_reboot.sh` по умолчанию только читает состояние.
Тест реального `unbind/bind` требует явного `--exercise-rebind`.
`tests/smoke.sh` запускает настоящий лимитер на обычных временных файлах:
проверяет повышение недостаточного лимита 0,6 А до 0,7 А, остановку по верхнему
порогу и температуре, а также поведение на границах диапазона. Отдельные
mock-команды проверяют, что обычная проверка ядра не пытается писать в sysfs.

## English

A device-specific battery charge limiter for a OnePlus 6 running Mobian as a
home server. A `systemd` service reads Linux power_supply sysfs and changes the
charger's input-current limit through `current_max`. SoC and temperature checks
are not a universal battery safety guarantee.

The public script defaults to a 40–80% range, observes every five minutes,
recovers charging below 40%, tunes the input-current limit from 0.5 A to 1 A,
and pauses above 80%. The supplied OnePlus 6 profile starts at 0.6 A instead
of the script's 0.5 A default: the lower limit was insufficient under the
author's container workload and caused `Charging/Discharging` oscillation.
Read-only verification of the running server on 4 October 2026 confirmed
`CURRENT_START=600000`. The profile remains a reproducible example, not an
export of all current server settings.
A 45 °C temperature lock clears below 40 °C. Boundaries
are strict: exactly 40% and 80% remain in range. Tuning is part of the low-SoC
workflow; the in-range monitor does not continuously adapt current to workload.
`current_max` is an input-current limit, not measured battery charging current.

Copy `battery-limiter.env.example` to the Git-ignored `battery-limiter.env`,
check paths and driver-specific current values, then run
`setup_battery_limiter.ps1` with explicit host, user and SSH key parameters as
shown above. The installer changes the system, restarts journald and the
limiter, and does not install the optional kernel override. Stopping the service
restores `STOP_CURRENT_MAX` / `CURRENT_DRIVER`; it does not switch charging off.

Auto-detection chooses the first matching battery gauge and the first
`current_max` node. Override paths on devices with multiple supplies. Recovery
may rebind the charger or its SPMI parent, which can affect related devices.
Read [kernel-patch/README.md](kernel-patch/README.md) before considering the
PMI8998 override: version 1.1 also disables two hardware charge safety timers.
The kernel verification helper is read-only by default; the explicit
`--exercise-rebind` option changes hardware state.

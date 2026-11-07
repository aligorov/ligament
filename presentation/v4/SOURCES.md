# Источники презентации Ligament

Дата проверки: 10 октября 2026.

## 1. Ligament

- /Users/aleksey/Documents/ligament/README.ru.md
- /Users/aleksey/Documents/ligament-apps/pubspec.yaml

## 2. Какие задачи решает Ligament

- /Users/aleksey/Documents/ligament/README.ru.md

## 3. Общая схема взаимодействия

- /Users/aleksey/Documents/2fa/README.md
- /Users/aleksey/Documents/2fa/internal/license/payload.go

## 4. Факторы подтверждения

- /Users/aleksey/Documents/2fa/README.md

## 5. Вход в Windows и RDP

- /Users/aleksey/Documents/ligament-apps/windows/credential_provider/LigamentProvider.cpp
- /Users/aleksey/Documents/ligament-apps/windows/credential_provider/HttpApiClient.cpp

## 6. UAC: подтверждение повышения прав

- /Users/aleksey/Documents/ligament-apps/windows/credential_provider/LigamentProvider.cpp
- /Users/aleksey/Documents/ligament-apps/windows/credential_provider/ligament-cp-settings.reg

## 7. VPN и Wi-Fi через RADIUS

- /Users/aleksey/Documents/2fa/internal/radiusserver
- /Users/aleksey/Documents/ligament/README.ru.md

## 8. SSO: единый вход в веб-сервисы

- /Users/aleksey/Documents/2fa/internal/oidc/handlers.go
- /Users/aleksey/Documents/2fa/internal/saml/handlers.go
- /Users/aleksey/Documents/2fa/internal/license/state.go

## 9. Приложения и самообслуживание

- /Users/aleksey/Documents/ligament-apps/pubspec.yaml
- /Users/aleksey/Documents/ligament-apps/README.md
- /Users/aleksey/Documents/2fa/README.md

## 10. Филиалы и автономная работа Relay

- /Users/aleksey/Documents/2fa/internal/api/admin_relays.go
- /Users/aleksey/Documents/2fa/internal/api/relay_hub.go
- /Users/aleksey/Documents/ligament/README.ru.md

## 11. Управление, аудит и эксплуатация

- /Users/aleksey/Documents/2fa/internal/metrics/metrics.go
- /Users/aleksey/Documents/2fa/internal/siem/service.go
- /Users/aleksey/Documents/2fa/internal/license/state.go
- /Users/aleksey/Documents/ligament/README.ru.md

## 12. Дополнительные сценарии

- /Users/aleksey/Documents/2fa/internal/bastion
- /Users/aleksey/Documents/2fa/internal/notifygw/service.go
- /Users/aleksey/Documents/2fa/internal/api/guests.go
- /Users/aleksey/Documents/ligament/README.ru.md

## 13. Free и коммерческие редакции

- /Users/aleksey/Documents/2fa/internal/license/state.go
- /Users/aleksey/Documents/2fa/internal/license/payload.go
- /Users/aleksey/Documents/ligament/README.ru.md

## 14. Что означает работа без интернета

- /Users/aleksey/Documents/2fa/internal/license/payload.go
- /Users/aleksey/Documents/2fa/internal/license/check.go

## 15. Сравнение моделей развёртывания

- /Users/aleksey/Documents/ligament/README.ru.md
- https://multifactor.ru/multifactor/
- https://mfasoft.ru/product
- https://indeed-cloud.ru/
- https://kontur.ru/partnership/blog/86244-partnerskaya_programma_konturegidy
- https://support.kontur.ru/id/88686-nastrojka_winlogon_dlya_onpremise

## 16. Сравнение подтверждённых возможностей

- /Users/aleksey/Documents/ligament/README.ru.md
- https://multifactor.ru/multifactor/
- https://mfasoft.ru/product
- https://indeed-cloud.ru/
- https://support.kontur.ru/id/86146-winlogon_dlya_oblachnogo_resheniya
- https://support.kontur.ru/id/45667-radius

## 17. Цены Ligament

- /Users/aleksey/Documents/ligament/README.ru.md

## 18. Как стоимость зависит от числа пользователей

- /Users/aleksey/Documents/ligament/README.ru.md

## 19. Затраты на лицензии за 1–3 года

- /Users/aleksey/Documents/ligament/README.ru.md
- /Users/aleksey/Documents/2fa/internal/license/payload.go

## 20. Публичные ценовые ориентиры аналогов

- https://multifactor.ru/licenzionnoe-soglashenie/
- https://mfasoft.ru/license
- https://indeed-cloud.ru/documents/uslovia-ispolzovania.pdf
- https://kontur.ru/partnership/blog/86244-partnerskaya_programma_konturegidy

## 21. Плюсы, ограничения и выбор решения

- /Users/aleksey/Documents/ligament/README.ru.md
- /Users/aleksey/Documents/2fa/internal/license/payload.go
- /Users/aleksey/Documents/ligament-apps/windows/credential_provider/LigamentProvider.cpp
- https://mfasoft.ru/product
- https://multifactor.ru/multifactor/

## 22. Пилот и источники

- /Users/aleksey/Documents/ligament/README.ru.md
- https://multifactor.ru/multifactor/
- https://mfasoft.ru/product
- https://indeed-cloud.ru/
- https://kontur.ru/partnership/blog/86244-partnerskaya_programma_konturegidy

## Модель стоимости

Локальный README указывает 2 USD/пользователь/месяц и 5 USD/пользователь бессрочно, оплату в USDT. Подписка Relay: 400 USD за узел за срок; бессрочная: 1000 USD за узел. Противоречие «13 месяцев» против «12 оплаченных + 1 бесплатно» не разрешалось изменением коммерческих условий: графики показывают 12 оплаченных месяцев без бонуса. N=25/100/500: 600/2400/12000 USD подписка; 125/500/2500 USD бессрочно. Для N=100 за 1/2/3 года: 2400/4800/7200 USD против базовой покупки 500 USD. Maintenance, сопровождение, инфраструктура, внедрение и доставка не включены; это не TCO. Курс USD/USDT/RUB не предполагается.

## Ограничения доказательств

Исходники и тесты подтверждают реализацию, но не заменяют приёмку опубликованной сборки. UAC — только credentialed-UAC при настройке Windows; по умолчанию отключён. Perpetual без онлайн-сверки; подписка и Demo могут иметь check_url. Доступность платных модулей проверяется по конкретной лицензии. Публичные цены аналогов — разные комплектации, не основание для рейтинга стоимости.

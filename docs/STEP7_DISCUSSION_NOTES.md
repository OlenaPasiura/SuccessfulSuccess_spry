# Step 7 — Discussion Notes (Think It Through) — Захист лабораторної роботи з Terraform

Цей документ містить структуровані відповіді та інженерні обґрунтування до контрольних питань **Step 7 (Think it through)** за результатами міграції проєкту **SuccessfulSuccess_spry** з AWS CloudFormation на Terraform та HCP Terraform (`ooad-OlenaPasiura` / `SuccessfulSuccess_spry-dev`).

---

## 1. Аналіз 38 імпортованих ресурсів та безпека перестворення Stateless-ресурсів

### Що було імпортовано
Під час міграції (`infra/imports.tf`) у стан воркспейсу `SuccessfulSuccess_spry-dev` було імпортовано **38 існуючих ресурсів AWS** із трьох логічних підсистем (`auth.tf`, `reports.tf`, `ai.tf`) з результатом `38 imported, 0 added, 0 destroyed`:
- **Auth (`infra/auth.tf`, 4 ресурси):**
  - `aws_cognito_user_pool.main` (`us-east-1_iLw5kuHui`)
  - `aws_cognito_user_pool_domain.main` (`successfulsuccess-565905128959`)
  - `aws_cognito_identity_provider.google` (`Google`)
  - `aws_cognito_user_pool_client.web` (`2p8n23jvd273kbd1eespm5bkgq`)
- **Reports (`infra/reports.tf`, 26 ресурсів):**
  - S3-бакет та його супутні конфігурації: `aws_s3_bucket.reports` (`successfulsuccess-reports-565905128959`), `aws_s3_bucket_public_access_block.reports`, `aws_s3_bucket_ownership_controls.reports`, `aws_s3_bucket_server_side_encryption_configuration.reports`, `aws_s3_bucket_lifecycle_configuration.reports`, `aws_s3_bucket_notification.reports`.
  - Мережа та черги: `aws_vpc_endpoint.s3` (`vpce-04fd92f39170e2841`), `aws_sqs_queue.report_requests`, `aws_sqs_queue.report_requests_dlq`.
  - Обчислення та логування: `aws_lambda_function.report_builder`, `aws_lambda_function.report_mailer`, `aws_cloudwatch_log_group.report_builder`, `aws_cloudwatch_log_group.report_mailer`, `aws_lambda_event_source_mapping.report_requests`, `aws_lambda_permission.report_mailer_s3`.
  - Розклад та пошта: `aws_scheduler_schedule.weekly_report`, `aws_sesv2_email_identity.domain` (`spry.org.ua`).
  - IAM-ролі та політики (9 ресурсів): `aws_iam_role.report_builder`, `aws_iam_role.report_scheduler`, `aws_iam_role.report_mailer` та відповідні `aws_iam_role_policy` / `aws_iam_role_policy_attachment`.
- **AI Agenda Parser (`infra/ai.tf`, 8 ресурсів):**
  - `aws_lambda_function.agenda_parser` (`successfulsuccess-agenda-parser`), `aws_lambda_function_url.agenda_parser`, `aws_cloudwatch_log_group.agenda_parser`, `aws_lambda_permission.agenda_parser_url`, `aws_lambda_permission.agenda_parser_invoke`, `aws_iam_role.agenda_parser`, `aws_iam_role_policy_attachment.agenda_parser_basic`, `aws_iam_role_policy.agenda_parser_bedrock`.

### Stateful vs Stateless ресурси: де перестворення безпечне, а де катастрофічне
- **Stateless-ресурси (безпечні для перестворення `-/+`):**
  - `aws_lambda_permission` (`report_mailer_s3`, `agenda_parser_url`, `agenda_parser_invoke`) — це лише запис у resource-based політиці Lambda. Його видалення та повторне створення займає долі секунди й не втрачає жодних даних користувачів.
  - `aws_s3_bucket_notification.reports` — конфігурація тригера подій `s3:ObjectCreated:*`. Перестворення не зачіпає об'єкти у S3-бакеті.
  - `aws_iam_role_policy` та `aws_iam_role_policy_attachment`, `aws_scheduler_schedule.weekly_report`, `aws_lambda_event_source_mapping.report_requests` — суто декларативні прив'язки прав або тригерів, які можна перестворити без втрати бізнес-даних.
- **Stateful-ресурси (перестворення НЕПРИПУСТИМЕ):**
  - `aws_cognito_user_pool.main` — містить облікові записи всіх зареєстрованих користувачів та їхні `sub` UUID.
  - `aws_s3_bucket.reports` — зберігає згенеровані тижневі звіти у `reports/*.csv`.
  - `aws_sesv2_email_identity.domain` (`spry.org.ua`) — має згенеровані DKIM-ключі, які вже прописані у DNS-зоні домену.

---

## 2. Незмінні атрибути (Immutable Attributes), що викликають Destructive Replacement (`-/+`), та наслідки для даних

У провайдері AWS частина атрибутів ресурсів є **immutable** на рівні AWS API — їх неможливо оновити викликом `Update*` (`~ update in-place`), тому зміна такого поля у `.tf` змушує Terraform запланувати знищення старого ресурсу та створення нового (`-/+ destroy and then create replacement`):

| Ресурс | Immutable-атрибут | Що станеться при зміні (`-/+`) | Наслідки для даних та системи |
|--------|-------------------|--------------------------------|-------------------------------|
| `aws_s3_bucket.reports` | `bucket` (назва бакета) | `-/+ must be replaced` | Всі збережені звіти `.csv` у старому бакеті будуть або втрачені (при `force_destroy = true`), або операція впаде з помилкою `BucketNotEmpty`. |
| `aws_cognito_user_pool.main` | `username_attributes`, `alias_attributes`, `schema` | `-/+ must be replaced` | **Повна втрата всіх користувачів**, зміна `user_pool_id` (`us-east-1_...`) та всіх `sub` у таблиці `users` БД PostgreSQL (усі старі мітинги втратять власників). Саме тому у `auth.tf` додано `lifecycle { ignore_changes = [schema] }`. |
| `aws_cognito_user_pool_domain.main` | `domain` | `-/+ must be replaced` | Тимчасова недоступність OAuth2/Google входу та зміна `redirect_uri`, який прописаний у Google Cloud Console. |
| `aws_sqs_queue.report_requests` | `name`, `fifo_queue` | `-/+ must be replaced` | Втрата всіх повідомлень, що перебували в черзі на момент перестворення, та 60-секундний кулдаун AWS SQS при перестворенні черги з тим самим іменем. |
| `aws_lambda_function.*` | `function_name`, `package_type` | `-/+ must be replaced` | Короткочасний даунтайм функції; для `agenda_parser` перестворення функції також викличе перестворення `aws_lambda_function_url.agenda_parser` зі зміною публічного домену `*.lambda-url.us-east-1.on.aws` (фронтенд перестане бачити AI-парсер до нового білду). |

---

## 3. Де зберігається `google_client_secret` (`sensitive = true`) та ризики витоку

Позначка `sensitive = true` у `variable "google_client_secret"` маскує значення лише у **консольному виводі CLI та логах HCP Terraform UI** (`(sensitive value)`), але сам секрет у відкритому або дешифрованому вигляді присутній у кількох місцях:

1. **Змінні воркспейсу HCP Terraform (`Workspace Variables`):**
   - Зберігається як Sensitive Terraform Variable `google_client_secret` у воркспейсі `SuccessfulSuccess_spry-dev`. Зашифрована у сховищі HCP Terraform (Vault-backed encryption) і недоступна для читання через UI або API після збереження.
2. **Файл стану Terraform (`terraform.tfstate`):**
   - Атрибут `aws_cognito_identity_provider.google.provider_details["client_secret"]` зберігається **у відкритому тексті всередині JSON-структури state-файлу**.
   - У нашому проєкті state зберігається віддалено у HCP Terraform (де він шифрується at-rest і передається через TLS), а локальні `*.tfstate` та `*.tfvars` додані у `.gitignore`.
3. **Конфігурація AWS Cognito API:**
   - Секрет зберігається на боці AWS у налаштуваннях Identity Provider `Google` пулу користувачів і може бути прочитаний будь-ким, хто має IAM-дозвіл `cognito-idp:DescribeIdentityProvider`.

### Основні вектори ризику витоку:
- **Коміт локального `terraform.tfstate` або `terraform.tfvars` у Git** — найпоширеніша помилка при роботі без remote backend.
- **Надмірні права читання State у HCP Terraform або S3** — будь-хто з правом читання state-файлу (`terraform state pull`) отримує `google_client_secret` у відкритому тексті.
- **Передача секрету через незахищені CI/CD логи** при відсутності прапорця `sensitive = true`.

---

## 4. Механізм State Locking у HCP Terraform проти конфліктів локального `tfstate` у Git

### Чому зберігати `terraform.tfstate` у Git — антипатерн:
1. **Race Conditions (стан гонитви):** Якщо два розробники (або два CI-пайплайни) одночасно запустять `terraform apply` зі своїми локальними копіями `terraform.tfstate`, обидва прочитають застарілий стан, паралельно викличуть AWS API (наприклад, створять дублікати ресурсів або перезапишуть політики), а потім при `git push` виникне merge-конфлікт у багатотисячному JSON-файлі `terraform.tfstate`, який неможливо безпечно розв'язати вручну.
2. **Витік секретів:** Будь-який секрет (`google_client_secret`, токени, паролі БД) назавжди залишається в історії Git-комітів.
3. **Забутий `git pull` / `git push`:** Якщо розробник застосував зміни у хмарі, але не запушив оновлений `.tfstate`, наступний запуск іншим учасником команди призведе до спроби повторного створення вже існуючих ресурсів (`EntityAlreadyExists`).

### Як це вирішує State Locking у HCP Terraform:
- Воркспейс `SuccessfulSuccess_spry-dev` у HCP Terraform зберігає **єдине централізоване джерело правди (Single Source of Truth)** для стану.
- Перед початком кожного `plan` / `apply` HCP Terraform автоматично встановлює **атомарне блокування стану (State Lock)** та ставить паралельні запуски у чергу виконання (Run Queue).
- Другий запуск не почнеться, доки перший повністю не завершиться і не запише нову ревізію стану (State Version), що повністю унеможливлює конкурентне пошкодження стану.

---

## 5. Принцип найменших привілеїв (Least Privilege) для AWS OIDC Ролі HCP Terraform

У лабораторному bootstrap-кроці (`~/tf-bootstrap`) ролі `tfc-workload-identity-role` для спрощення було надано політику `AdministratorAccess` та довіру на рівні всієї організації `organization:ooad-OlenaPasiura:project:*:workspace:*:run_phase:*`. Для production-середовища необхідно звузити як **Trust Policy**, так і **Permissions Policy**:

### 5.1. Звужена IAM Trust Policy (прив'язка виключно до воркспейсу `SuccessfulSuccess_spry-dev`)
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::565905128959:oidc-provider/app.terraform.io"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "app.terraform.io:aud": "aws.workload.identity"
        },
        "StringLike": {
          "app.terraform.io:sub": "organization:ooad-OlenaPasiura:project:*:workspace:SuccessfulSuccess_spry-dev:run_phase:*"
        }
      }
    }
  ]
}
```
Така умова гарантує, що жоден інший тестовий воркспейс в організації `ooad-OlenaPasiura` (наприклад, `tf-playground`) не зможе отримати доступ до production/dev ресурсів проєкту `SuccessfulSuccess_spry`.

### 5.2. Звужена IAM Permissions Policy (замість `AdministratorAccess`)
Ролі потрібні права лише на ті сервіси та префікси ресурсів (`successfulsuccess-*`), якими керує Terraform у `infra/`:
- **S3 (`s3:*`):** `s3:CreateBucket`, `s3:DeleteBucket`, `s3:Get*`, `s3:PutBucketPublicAccessBlock`, `s3:PutBucketOwnershipControls`, `s3:PutEncryptionConfiguration`, `s3:PutLifecycleConfiguration`, `s3:PutBucketNotification`, `s3:PutBucketTagging` на `arn:aws:s3:::successfulsuccess-*`.
- **Cognito (`cognito-idp:*`):** `cognito-idp:CreateUserPool*`, `cognito-idp:UpdateUserPool*`, `cognito-idp:DescribeUserPool*`, `cognito-idp:CreateIdentityProvider`, `cognito-idp:UpdateIdentityProvider`, `cognito-idp:DescribeIdentityProvider`, `cognito-idp:TagResource` у межах регіону `us-east-1`.
- **Lambda & Logs (`lambda:*`, `logs:*`):** `lambda:CreateFunction`, `lambda:UpdateFunctionCode`, `lambda:UpdateFunctionConfiguration`, `lambda:Get*`, `lambda:AddPermission`, `lambda:RemovePermission`, `lambda:CreateFunctionUrlConfig`, `lambda:UpdateFunctionUrlConfig`, `lambda:CreateEventSourceMapping`, `lambda:TagResource` на `arn:aws:lambda:us-east-1:565905128959:function:successfulsuccess-*` та `logs:*` на `/aws/lambda/successfulsuccess-*`.
- **SQS, EventBridge Scheduler, SES, EC2 VPC Endpoint, IAM:** точкові дії на ресурси з префіксом `successfulsuccess-*` та `iam:PassRole` лише для ролей `successfulsuccess-*-role`.

---

## 6. Межі автономності AI-агентів (Claude Code / Antigravity) при створенні та зміні інфраструктури

Під час створення нового середовища (наприклад, `staging`) за допомогою AI-агента інженер має чітко розмежовувати безпечні автономні дії агента та дії, що вимагають обов'язкового підтвердження людиною (Human-in-the-Loop):

### Що AI-агент може виконувати автономно (Безпечна зона):
1. **Генерація та рефакторинг HCL-коду:** створення модулів, параметризація імен ресурсів через `var.env` (`successfulsuccess-${var.env}-...`), написання `staging.tfvars`.
2. **Статичний аналіз та валідація:** запуск `terraform fmt`, `terraform validate`, `tflint`, перевірка відсутності захардкоджених секретів.
3. **Спекулятивні плани (`terraform plan` / `make infra-plan`):** запуск read-only планування для перевірки очікуваного diff (`to add`, `to change`, `to destroy`).

### Де потрібне обов'язкове схвалення людиною (Межа автономності):
1. **Виконання `terraform apply` та `terraform destroy`:** AI-агент не повинен самостійно підтверджувати плани у production/staging, особливо якщо план містить `to destroy` або `-/+ forces replacement` на stateful-ресурсах (Cognito, S3, RDS/Aurora).
2. **Зміна IAM Trust Policies та OIDC ролей (`aws_iam_role`, `AdministratorAccess`):** будь-яке розширення прав доступу має проходити ручне code review, щоб уникнути privilege escalation.
3. **Робота зі станом (`terraform state rm`, `mv`, `force-unlock`) та видалення стеків:** ручні маніпуляції зі state-файлом або прапорцями `force_destroy = true` можуть призвести до незворотної втрати даних або розсинхронізації інфраструктури.
4. **Конфігурація білінгових лімітів та платних сервісів:** створення NAT Gateway, RDS/Aurora інстансів або високопродуктивних LLM-ендпоінтів має затверджуватися людиною для контролю витрат AWS.

# ☁️ Nubeduca

**Tu institución educativa, en la nube.**

Nubeduca es un **LMS (Learning Management System) SaaS multi-tenant**: una sola plataforma que varias instituciones educativas usan al mismo tiempo, cada una con sus datos totalmente aislados. Proyecto Final del curso **CS2032 Cloud Computing (UTEC, 2026-2)**.

> **Para empezar:** lee la [arquitectura](#️-arquitectura), busca tus tareas en [Equipo y responsabilidades](#-equipo-y-responsabilidades) y trabaja siempre contra los contratos de [`nubeduca-contratos`](https://github.com/nubeduca/nubeduca-contratos).

---

## 🎯 Qué hace

| Usuario | Puede |
|---|---|
| 👩‍🏫 **Docente** | Crear cursos y matricular alumnos (CSV), publicar módulos con archivos, crear tareas, calificar y publicar notas, enviar anuncios |
| 🧑‍🎓 **Estudiante** | Ver sus cursos y módulos, descargar materiales, entregar tareas, ver sus notas y recibir avisos por email |
| 🛠️ **Administrador** | Gestionar la institución, sus periodos académicos y sus usuarios |
| 🏫 **Tenant** | Cada institución: `utec`, `upc`, `pucp` |

**Gate de la Fase 1 (lo que se demuestra con 2 tenants):** en el curso piloto, el docente publica contenido y una tarea, los alumnos entregan, el docente califica y cada alumno ve su nota y recibe el aviso.

---

## ✅ Requisitos del proyecto (enunciado del profesor)

La rúbrica manda: si el diseño choca con ella, gana la rúbrica.

| Requisito | Cómo lo cumplimos | Tareas |
|---|---|---|
| SaaS multi-tenant | `tenant_id` en el token, en cada evento y en la clave de cada tabla | AUTH-01, LIB-01 |
| Serverless | API Gateway + Lambda, DynamoDB, EventBridge, SQS y SNS | LIB-01, PLT-05 |
| Basada en eventos | Outbox con DynamoDB Streams + Pipes → EventBridge → una SQS por consumidor; SNS FIFO para notas | PLT-04, GATE-0 |
| Mínimo 5 microservicios protegidos | 6 microservicios, cada uno con su API Gateway y authorizer de Cognito | AUTH-01, PLT-05 |
| BD propia por microservicio | DynamoDB en los 6 (ADR-007) | — |
| Estructura JSON por microservicio | En el README de cada `nubeduca-ms-*` y en el informe | Tareas con seed, DOC-02 |
| 30.000 registros en 3 tenants | `poblar_datos.py` por microservicio: UTEC 15.000, UPC 10.000 y PUCP 5.000 | ACA-02, ACA-03, CON-02, EVA-01, EVA-02, ENG-01 |
| Uso de S3, SNS y SQS | S3 para archivos y entregas, SNS para notas (FIFO) y email, SQS por consumidor | CON-01, PLT-04, ENG-01 |
| Despliegue con Serverless Framework | Un `serverless.yml` por stack, incluidos el frontend en Amplify y la VM de despliegue | PLT-01 a PLT-06 |
| Frontend en Amplify | Shell web y pantallas por módulo | FE-01, FE-02, FE-03 |
| Diagrama de arquitectura | draw.io con íconos AWS | DOC-01 |
| Demo con 2 tenants | Guion y video con UTEC y UPC | QA-01, DOC-03 |
| Informe y PowerPoint | Informe con enlaces a los repos y diseño de BD | DOC-02, DOC-03 |

---

## 🏗️ Arquitectura

![Arquitectura de Nubeduca](https://raw.githubusercontent.com/nubeduca/.github/main/nubeduca-arquitectura.drawio.png)

*Diagrama de Dev 3 (versión con los cambios de PLT-04). Editable: [`nubeduca-arquitectura.drawio`](https://github.com/nubeduca/.github/blob/main/nubeduca-arquitectura.drawio)*

### Cómo fluye una petición

1. El navegador carga el frontend desde **AWS Amplify Hosting**.
2. El usuario inicia sesión en **Amazon Cognito**. El token trae `tenant_id` y rol.
3. Cada llamada va a la **API Gateway** del microservicio dueño. El authorizer de Cognito valida el token, y la Lambda toma `tenant_id` del token, nunca del body.
4. La **Lambda** escribe el cambio en la tabla **DynamoDB** de su microservicio y, en la misma transacción, el evento (registro `EVENTO#`) **validado contra su esquema**. Ningún microservicio lee la tabla de otro. Los archivos suben directo a **S3** con URL prefirmada.
5. **DynamoDB Streams** lleva cada evento al bus **`lms-<stage>`** con una Lambda relay (o con **EventBridge Pipes**, `--param="outbox=pipe"`, pendiente de validar en el Learner Lab). **Archive** permite reprocesar. Los esquemas viven en el repo [`nubeduca-contratos`](https://github.com/nubeduca/nubeduca-contratos), que la CI valida (el Schema Registry no está disponible en el Learner Lab).
6. Una **regla** por consumidor copia el evento a su cola **SQS** con **DLQ**. La Lambda consumidora lo procesa una sola vez (idempotente).
7. ms-calificaciones publica además las notas en **SNS FIFO** con grupo `tenant_id:course_id`, y llegan en orden a la cola **SQS FIFO** de ms-notificaciones.
8. ms-notificaciones avisa por **email** con Amazon SNS, según las preferencias del usuario.
9. **CloudWatch** y **X-Ray** observan todo. **Serverless Framework** despliega cada microservicio como un stack de CloudFormation.

### Principios

1. **Cada servicio es dueño de sus datos.** Nadie lee ni escribe la base de otro. Se integra por eventos o por su API.
2. **Eventos = hechos en pasado** (`submission.graded`). Los comandos son llamadas síncronas al servicio dueño, nunca mensajes en el bus.
3. **Coreografía por defecto.** Los servicios reaccionan a eventos sin conocerse entre sí.
4. **Transactional outbox.** El cambio y el evento se guardan en la misma transacción. Nunca "guardar y luego publicar".
5. **Consumidores idempotentes.** La entrega es at-least-once: cada consumidor registra el `eventId` y descarta duplicados.
6. **Orden solo donde importa** (notas): SNS FIFO → SQS FIFO. En el resto se descartan eventos con `aggregateVersion` vieja.
7. **Contratos versionados.** Un cambio incompatible es un tipo nuevo (`.v2`).
8. **Multi-tenant desde el día uno.** `tenant_id` va en el token, en cada evento y en la clave de partición.

### Decisiones tomadas (ADR)

| ADR | Decisión |
|---|---|
| ADR-001 | **6 microservicios desplegables**, cada uno agrupa varios dominios lógicos |
| ADR-002 | **Construir desde cero** (no envolver Moodle) |
| ADR-003 | **EventBridge + SQS / SNS** como broker de eventos |
| ADR-005 | **Pool:** los 3 tenants comparten tablas, con `tenant_id` en la clave |
| ADR-006 | **Lambda + API Gateway** para el cómputo |
| ADR-007 | **DynamoDB** en los 6 microservicios (sin VPC ni RDS) |

El documento completo de arquitectura de solución (contexto, mapa de capacidades vs. Moodle/Canvas/Blackboard, catálogo de 21 servicios, patrones, stack, riesgos y prueba de estrés) lo mantiene Dev 3.

---

## 🧩 Microservicios y eventos

Los 21 servicios lógicos del diseño se agrupan en **6 microservicios**, uno por repo `nubeduca-ms-*`. Cada uno tiene su API Gateway, sus Lambdas, su tabla DynamoDB y su seed de 30.000 registros.

| Microservicio | Servicios lógicos | `source` | Publica | Consume | Tareas |
|---|---|---|---|---|---|
| **ms-usuarios** | Tenant y Organización, Usuarios y Perfiles | `lms.users` | `tenant.created`, `term.started`, `user.provisioned` | — | ACA-01, ACA-02 |
| **ms-cursos** | Cursos y Secciones, Matrícula, Anuncios | `lms.courses` | `course.created`, `course.published`, `course.archived`, `enrollment.created`, `enrollment.dropped`, `announcement.published` | `term.started`, `user.provisioned` | ACA-03, ACA-04, COL-01 |
| **ms-contenidos** | Contenido y Módulos, Archivos y Media (S3) | `lms.content` | `file.scanned`, `module.published` | `course.created`, `enrollment.*` | CON-01, CON-02 |
| **ms-evaluaciones** | Tareas y Entregas | `lms.assessment` | `assignment.published`, `submission.submitted`, `submission.graded` | `enrollment.*`, `file.scanned` | EVA-01 |
| **ms-calificaciones** | Calificaciones, Auditoría de notas | `lms.grading` | `grade.changed`, `grade.posted` (bus + SNS FIFO) | `assignment.published`, `enrollment.*`, `submission.graded` | EVA-02, DAT-01 |
| **ms-notificaciones** | Notificaciones | — | — | `user.provisioned`, `course.published`, `enrollment.*`, `announcement.published`, `module.published`, `assignment.published`, `submission.submitted`, `grade.posted` | ENG-01 |

Los **16 eventos** del MVP siguen el formato `lms.<contexto>.<entidad>.<hecho>.v1` (por ejemplo `lms.content.file.scanned.v1`). Sus esquemas JSON, un ejemplo de cada uno y los contratos OpenAPI de los 6 microservicios están en [`nubeduca-contratos`](https://github.com/nubeduca/nubeduca-contratos). **Ningún microservicio publica un evento ni expone una ruta que no esté ahí.**

---

## 📦 Repositorios

| Repo | Contenido | Dueño | Estado |
|---|---|---|---|
| [`.github`](https://github.com/nubeduca/.github) | Este README y el diagrama de arquitectura | Dev 5 | 🟢 Activo |
| [`nubeduca-backlog`](https://github.com/nubeduca/nubeduca-backlog/issues) | Las 33 tareas como issues: fase, ola, dependencias y responsable | Dev 3 | 🟢 Activo |
| [`nubeduca-contratos`](https://github.com/nubeduca/nubeduca-contratos) | Catálogo de 16 eventos, JSON Schema, OpenAPI de los 6 microservicios y validación en CI | Dev 3 | 🟢 v1 publicada (ARQ-01) |
| [`nubeduca-backend`](https://github.com/nubeduca/nubeduca-backend) | Solo infraestructura (D1): `infra/base`, `infra/bus`, `infra/frontend` (Amplify), `infra/despliegue` (VM), `localstack/` y `scripts/desplegar.sh` | Dev 1 y 2 | 🟢 Base, bus, CORS y Amplify como IaC en `main`; `desplegar.sh` y la VM en [PR #8](https://github.com/nubeduca/nubeduca-backend/pull/8) |
| [`nubeduca-frontend`](https://github.com/nubeduca/nubeduca-frontend) | React + TypeScript + Vite en Amplify, con mocks MSW hasta AUTH-01 | Dev 6 | 🟡 FE-01 publicado; FE-02, FE-03 y avisos reales en PRs #1, #2 y #3 (encadenados) |
| [`nubeduca-plantilla-servicio`](https://github.com/nubeduca/nubeduca-plantilla-servicio) | Plantilla que copia cada microservicio: outbox, inbox idempotente, validación de esquemas y `serverless.yml` base | Dev 3 y 5 | 🟢 LIB-01 cerrado (15 tests); X-Ray y alarmas en PR #4 |
| [`nubeduca-ms-usuarios`](https://github.com/nubeduca/nubeduca-ms-usuarios) | Tenant, periodos, usuarios y perfiles | Dev 3 y 4 | 🟢 ACA-01 en `main` (29 tests); ACA-02 pendiente |
| [`nubeduca-ms-cursos`](https://github.com/nubeduca/nubeduca-ms-cursos) | Cursos, secciones, matrícula CSV y anuncios | Dev 3 y 4 | 🟢 ACA-03 en `main` (37 tests, seed de 30.000); ACA-04 y COL-01 pendientes |
| [`nubeduca-ms-contenidos`](https://github.com/nubeduca/nubeduca-ms-contenidos) | Archivos en S3 con antivirus, módulos e ítems | Dev 5 | ⚪ Solo README |
| [`nubeduca-ms-evaluaciones`](https://github.com/nubeduca/nubeduca-ms-evaluaciones) | Tareas y entregas | Dev 4 | ⚪ Solo README |
| [`nubeduca-ms-calificaciones`](https://github.com/nubeduca/nubeduca-ms-calificaciones) | Libro de notas, publicación por SNS FIFO y auditoría | Dev 4, 3 y 5 | 🟠 Base del diseño anterior, falta rehacerla desde la plantilla |
| [`nubeduca-ms-notificaciones`](https://github.com/nubeduca/nubeduca-ms-notificaciones) | Consumidores SQS y email por SNS | Dev 6 | 🟢 ENG-01 desplegado en la cuenta de Dev 6; seed 15/10/5 y sin `org` fija en PR #1 |
| [`nubeduca-infra`](https://github.com/nubeduca/nubeduca-infra) | Repo anterior, reemplazado por `nubeduca-backend` | — | ⚫ Archivado |

---

## 👥 Equipo y responsabilidades

Las asignaciones son las de la **arquitectura de solución** (sección 9). Con 6 devs, cada persona cubre un dominio o una capa; los squads se forman cuando el equipo crezca. Las tareas viven como **issues** en [`nubeduca-backlog`](https://github.com/nubeduca/nubeduca-backlog/issues): cada issue indica su fase, su ola, de qué depende y cuándo está listo.

| Dev | Integrante | Área principal |
|---|---|---|
| **1** | Fabricio · [@cruz-eng](https://github.com/cruz-eng) | Plataforma AWS: stages, stack base, API Gateway, despliegue continuo, staging y producción |
| **2** | Mariano · [@MarianoUtec](https://github.com/MarianoUtec) | Infraestructura y CI, bus de eventos, Cognito (AUTH-01) e informe final |
| **3** | Benjamin · [@btoroled](https://github.com/btoroled) | Arquitectura y contratos; dominio académico: tenant, cursos, matrícula y anuncios |
| **4** | Brando · [@Edinson695](https://github.com/Edinson695) | Entorno local (LocalStack), usuarios, tareas y entregas, calificaciones |
| **5** | Alexander · [@AIexander-lx](https://github.com/AIexander-lx) | Diagrama de arquitectura, plantilla de servicio, contenidos (S3 y módulos) y auditoría de notas |
| **6** | Guillermo · [@Guillermo-Heredia](https://github.com/Guillermo-Heredia) | Frontend en Amplify, notificaciones por email, PowerPoint y video de la demo |

### Tareas de cada integrante

| Dev | Fase 0 · Fundaciones | Fase 1 · MVP académico |
|---|---|---|
| **1 · Fabricio** | [PLT-01](https://github.com/nubeduca/nubeduca-backlog/issues/4) Cuenta AWS y stages · [PLT-03](https://github.com/nubeduca/nubeduca-backlog/issues/8) Stack base · [PLT-05](https://github.com/nubeduca/nubeduca-backlog/issues/15) API Gateway y borde · [PLT-06](https://github.com/nubeduca/nubeduca-backlog/issues/18) CD y alarmas · [GATE-0](https://github.com/nubeduca/nubeduca-backlog/issues/22) *(con Dev 2)* | [REL-01](https://github.com/nubeduca/nubeduca-backlog/issues/28) MVP en staging *(con Dev 2)* · [REL-02](https://github.com/nubeduca/nubeduca-backlog/issues/33) Producción y piloto *(con Dev 3)* · opcionales: [PERF-01](https://github.com/nubeduca/nubeduca-backlog/issues/26), [PERF-02](https://github.com/nubeduca/nubeduca-backlog/issues/30) |
| **2 · Mariano** | [PLT-02](https://github.com/nubeduca/nubeduca-backlog/issues/5) Infraestructura y CI · [PLT-04](https://github.com/nubeduca/nubeduca-backlog/issues/14) Bus de eventos · [AUTH-01](https://github.com/nubeduca/nubeduca-backlog/issues/17) Cognito y tenant en el token · [GATE-0](https://github.com/nubeduca/nubeduca-backlog/issues/22) *(con Dev 1)* | [REL-01](https://github.com/nubeduca/nubeduca-backlog/issues/28) *(con Dev 1)* · [DOC-02](https://github.com/nubeduca/nubeduca-backlog/issues/29) **Informe final** · opcionales: [PERF-01](https://github.com/nubeduca/nubeduca-backlog/issues/26), [PERF-02](https://github.com/nubeduca/nubeduca-backlog/issues/30) |
| **3 · Benjamin** | [ARQ-01](https://github.com/nubeduca/nubeduca-backlog/issues/1) Catálogo de eventos · [LIB-01](https://github.com/nubeduca/nubeduca-backlog/issues/7) Plantilla de servicio *(con Dev 5)* | [ACA-01](https://github.com/nubeduca/nubeduca-backlog/issues/9) Tenant y organización · [ACA-03](https://github.com/nubeduca/nubeduca-backlog/issues/16) Cursos *(con Dev 4)* · [ACA-04](https://github.com/nubeduca/nubeduca-backlog/issues/19) Matrícula CSV · [COL-01](https://github.com/nubeduca/nubeduca-backlog/issues/23) Anuncios · [EVA-02](https://github.com/nubeduca/nubeduca-backlog/issues/27) Calificaciones *(con Dev 4)* · [REL-02](https://github.com/nubeduca/nubeduca-backlog/issues/33) *(con Dev 1)* |
| **4 · Brando** | [LOC-01](https://github.com/nubeduca/nubeduca-backlog/issues/3) Entorno local con LocalStack | [ACA-02](https://github.com/nubeduca/nubeduca-backlog/issues/10) Usuarios y perfiles · [ACA-03](https://github.com/nubeduca/nubeduca-backlog/issues/16) Cursos *(con Dev 3)* · [EVA-01](https://github.com/nubeduca/nubeduca-backlog/issues/24) Tareas y entregas · [EVA-02](https://github.com/nubeduca/nubeduca-backlog/issues/27) Calificaciones *(con Dev 3)* |
| **5 · Alexander** | [DOC-01](https://github.com/nubeduca/nubeduca-backlog/issues/6) **Diagrama de arquitectura** · [LIB-01](https://github.com/nubeduca/nubeduca-backlog/issues/7) Plantilla de servicio *(con Dev 3)* | [CON-01](https://github.com/nubeduca/nubeduca-backlog/issues/11) Archivos y media · [DAT-01](https://github.com/nubeduca/nubeduca-backlog/issues/12) Auditoría de notas · [CON-02](https://github.com/nubeduca/nubeduca-backlog/issues/20) Contenido y módulos |
| **6 · Guillermo** | [FE-01](https://github.com/nubeduca/nubeduca-backlog/issues/2) Shell web en Amplify | [ENG-01](https://github.com/nubeduca/nubeduca-backlog/issues/13) Notificaciones por email · [FE-02](https://github.com/nubeduca/nubeduca-backlog/issues/21) UI académica · [FE-03](https://github.com/nubeduca/nubeduca-backlog/issues/25) UI de tareas y notas · [DOC-03](https://github.com/nubeduca/nubeduca-backlog/issues/32) **PowerPoint, guion y video** |
| **Todos** | — | [QA-01](https://github.com/nubeduca/nubeduca-backlog/issues/31) E2E del curso piloto con 2 tenants |

**Ruta crítica:** ARQ-01 → LIB-01 → Tenant → Cursos → Matrícula → Tareas → Notas → staging → producción. Si una de estas tareas se atrasa, se suma un segundo dev en vez de apurar el resto.

**La Ola 3 es la más cargada** (7 tareas para 6 personas): Dev 5 toma DAT-01 después de CON-01. La Fase 1 no espera a GATE-0: arranca en la Ola 3, apenas está la plantilla de servicio.

---

## 📍 Estado actual · 13 de noviembre

**12 de 33 tareas cerradas (36 %):** ARQ-01, LOC-01, PLT-01, PLT-02, FE-01, LIB-01, PLT-03, DOC-01, PLT-04, PLT-05, ACA-01 y ACA-03.

| Tarea | Responsable | Estado | Dónde |
|---|---|---|---|
| Olas 1 y 2 completas, más PLT-04 y PLT-05 | Dev 1, 2, 3, 4, 5 y 6 | 🟢 Cerradas | [`nubeduca-backend`](https://github.com/nubeduca/nubeduca-backend), [`nubeduca-contratos`](https://github.com/nubeduca/nubeduca-contratos), [`nubeduca-plantilla-servicio`](https://github.com/nubeduca/nubeduca-plantilla-servicio) |
| [ACA-01](https://github.com/nubeduca/nubeduca-backlog/issues/9) Tenant y organización | Dev 3 | 🟢 Cerrada: `tenant.created` y `term.started` | [`nubeduca-ms-usuarios`](https://github.com/nubeduca/nubeduca-ms-usuarios) |
| [ACA-03](https://github.com/nubeduca/nubeduca-backlog/issues/16) Cursos y secciones | Dev 3 y 4 | 🟢 Cerrada: `course.created`, `course.published`, `course.archived` y seed de 30.000 | [`nubeduca-ms-cursos`](https://github.com/nubeduca/nubeduca-ms-cursos) |
| [PLT-06](https://github.com/nubeduca/nubeduca-backlog/issues/18) Despliegue continuo y alarmas | Dev 1 | 🟡 Amplify como IaC en `main`; `desplegar.sh`, VM, X-Ray y alarmas en PRs | [PR #8](https://github.com/nubeduca/nubeduca-backend/pull/8) |
| [ENG-01](https://github.com/nubeduca/nubeduca-backlog/issues/13) Notificaciones por email | Dev 6 | 🟡 Probado en AWS; falta desplegarlo en la cuenta de integración | [`nubeduca-ms-notificaciones`](https://github.com/nubeduca/nubeduca-ms-notificaciones) |
| [FE-02](https://github.com/nubeduca/nubeduca-backlog/issues/21) y [FE-03](https://github.com/nubeduca/nubeduca-backlog/issues/25) Pantallas | Dev 6 | 🟡 PRs encadenados, ninguno llega a `main` | [PRs #1 a #3](https://github.com/nubeduca/nubeduca-frontend/pulls) |
| [ACA-02](https://github.com/nubeduca/nubeduca-backlog/issues/10) Usuarios y perfiles | Dev 4 | ⚪ Lista para empezar; **bloquea ACA-04** (ruta crítica) | [`nubeduca-ms-usuarios`](https://github.com/nubeduca/nubeduca-ms-usuarios) |
| [AUTH-01](https://github.com/nubeduca/nubeduca-backlog/issues/17) Cognito | Dev 2 | 🟡 `infra/auth` en `main` (PR #9); falta cerrar el issue y conectar los servicios con `authMode=cognito` | [`nubeduca-backend/infra/auth`](https://github.com/nubeduca/nubeduca-backend/tree/main/infra/auth) |

**Nombre del bus:** `infra/base` y `infra/bus` crean un bus **por stage** (`lms-dev`, `lms-staging`, `lms-prod`) y guardan el nombre en el parámetro SSM `/nubeduca/<stage>/bus-name`. Cada servicio lee ese nombre en vez de escribir `lms` fijo. En LocalStack el bus sigue llamándose `lms`.

**URLs de las APIs:** cada microservicio publica la suya en SSM (`/nubeduca/<stage>/api/<ms>/url`), y el stack de Amplify la pasa al frontend como `VITE_API_*`.

---

## 🎯 Avance del 30 % · viernes 13 de noviembre

La rúbrica le da **3 puntos** a la exposición virtual con el asesor y pide un **avance proporcional al 30 %**. Se presentan las olas 1 y 2 completas, PLT-04 y PLT-05 (10 tareas), y además ACA-01 y ACA-03: **12 de 33 cerradas**.

**Lo que ve el asesor:**
- Diagrama de arquitectura y catálogo de 16 eventos con los contratos OpenAPI
- Frontend publicado en Amplify con login simulado; el hosting también se levanta con IaC en cualquier cuenta
- La plantilla de servicio: outbox con validación de esquemas e inbox idempotente
- ms-usuarios y ms-cursos: el periodo que inicia ms-usuarios llega por el bus a ms-cursos, que solo crea cursos en periodos activos
- ms-notificaciones desplegado en AWS: un evento del bus termina en un email
- En AWS el outbox corre con la Lambda relay; EventBridge Pipes (`outbox=pipe`) está pendiente de validar en el Learner Lab

---

## 🚀 Despliegue e IaC

Toda la infraestructura se declara con **Serverless Framework v4**: un `serverless.yml` por stack. Lo integrado se despliega en **una sola cuenta**, el Learner Lab de Dev 3 (D2), desde la VM `nubeduca-despliegue` con `scripts/desplegar.sh <stage>`, en orden **base → bus → auth → microservicios → frontend**.

| Stack | Qué crea | Repo |
|---|---|---|
| `infra/base` | Bucket de despliegue y parámetros SSM compartidos | `nubeduca-backend` |
| `infra/bus` | Bus `lms-<stage>` de EventBridge, Archive y SNS FIFO de notas | `nubeduca-backend` |
| `infra/auth` | User Pool y App Client de Cognito con `tenant_id` y rol en el token (AUTH-01, en `main`) | `nubeduca-backend` |
| `infra/frontend` | App y rama de Amplify, rewrite de la SPA y variables `VITE_*` leídas de SSM | `nubeduca-backend` |
| `infra/despliegue` | VM `nubeduca-despliegue` con `LabInstanceProfile`, sin puertos (Session Manager) | `nubeduca-backend` |
| Cada microservicio | API Gateway + Lambdas + tabla DynamoDB + regla, cola SQS, DLQ y alarma de su consumidor | `nubeduca-ms-*` |

| Tema | Decisión |
|---|---|
| Repos (D1) | Un repo por microservicio (`nubeduca-ms-*`, creado desde la plantilla); `nubeduca-backend` es solo infraestructura |
| Cuenta de integración (D2) | El Learner Lab de Dev 3; se despliega desde la VM con el rol de la instancia |
| Credenciales | Cada dev usa un `.env` propio (está en `.gitignore`). `scripts/cuenta.sh` verifica la cuenta antes de desplegar |
| Org de Serverless | Los `serverless.yml` no fijan `org:` (salvo `infra/auth`, provisional); se usa la org del equipo vía `SERVERLESS_ACCESS_KEY` (por crear) |
| Conexión entre stacks | Por parámetros SSM `/nubeduca/<stage>/...`; nadie copia ARNs a mano |
| Consumidores | Cada servicio declara en su propio stack la regla de EventBridge, su cola, su DLQ y su alarma; el bus solo se crea en `infra/bus` |
| CI | GitHub Actions en cada repo: lint y tests en cada PR; `nubeduca-contratos` valida los esquemas y su compatibilidad |
| Observabilidad | X-Ray en API Gateway y Lambda, y alarmas de CloudWatch en cada DLQ |
| Eventos nuevos | Orden: esquema en `nubeduca-contratos` → regla y cola del consumidor → productor |

---

## 📐 Reglas de trabajo

- **Un servicio, un equipo dueño; un tipo de evento, un solo productor.**
- Suscribirse a un evento no requiere pedir permiso: el contrato vive en `nubeduca-contratos` y el productor no puede romperlo (lo valida antes de escribir).
- **Event storming por dominio** antes de cada fase del roadmap.
- **Toda decisión estructural queda como ADR** en el repositorio. Un PR que rompa uno de los principios de arquitectura necesita un ADR.
- **Definition of Done:** eventos documentados en AsyncAPI, test de contrato en CI, dashboard, alertas y runbook.
- Repos **públicos** dentro de la organización `nubeduca`.
- Cada tarea se trabaja desde su **issue**. El PR menciona el ID de la tarea (por ejemplo `CON-01`).
- **Ningún PR se mergea sin la revisión de otro dev.** Los contratos de eventos y la plantilla de servicio los aprueba Dev 3.
- **Python 3.13** + **Serverless Framework v4** con los stages `dev`, `staging` y `prod`.
- Rol IAM: `arn:aws:iam::${aws:accountId}:role/LabRole`. En el Learner Lab no se pueden crear roles.
- Tablas: `${sls:stage}-t_<nombre>`, con **`tenant_id` en la clave de partición**.
- Tenants: `utec`, `upc`, `pucp` · Roles: `STUDENT`, `TEACHER`, `ADMIN`.
- `tenant_id` y rol salen del **token de Cognito** (`custom:tenant_id`, `custom:role`), nunca de la ruta ni del body.
- Ids, rutas y campos en **inglés y camelCase**; textos para el usuario en español.
- Los eventos llevan **payload mínimo** (ids y lo que cambió), nada de nombres ni correos. Un archivo viaja como `fileId`.
- `poblar_datos.py` **no** escribe ítems `EVENTO#`, para no inundar el bus al cargar los 30.000 registros.
- Antes de desplegar en AWS, se prueba en local con [LocalStack](https://github.com/nubeduca/nubeduca-backend/tree/main/localstack) o con moto.
- Cada microservicio incluye: `serverless.yml`, Lambdas, `poblar_datos.py` (30.000 registros: UTEC 15.000, UPC 10.000 y PUCP 5.000), colección de Postman y README con la estructura JSON de sus tablas.

---

## 🗺️ Roadmap

Para el curso se entregan la **Fase 0** y la **Fase 1**. La prueba de estrés es un adicional y las Fases 2 a 4 quedan como roadmap.

| Fase | Contenido | Gate |
|---|---|---|
| **0 · Fundaciones** | Learner Lab, EventBridge (contratos en `nubeduca-contratos`), SQS con DLQ, despliegue con `desplegar.sh`, CloudWatch + X-Ray, Cognito, API Gateway, plantilla de servicio | Un servicio publica por outbox, otro consume de forma idempotente y la traza se ve de punta a punta |
| **1 · MVP académico** | Tenant, usuarios, cursos, matrícula CSV, contenido y módulos, archivos, tareas y entregas, calificaciones, anuncios, notificaciones y auditoría de notas | Contenido → tarea → entrega → nota → aviso, con 2 tenants |
| 2 · Evaluación y colaboración | Quizzes (QTI), rúbricas, LTI 1.3, calendario, foros, mensajería, app móvil | — |
| 3 · Engagement y analítica | Progreso, certificados, LRS (xAPI), reportes, búsqueda | — |
| 4 · Ecosistema | SCORM / cmi5, Common Cartridge, webhooks públicos, pagos | — |

# Nubeduca — Contratos y dependencias por rol

Este documento tiene **toda la información que cada rol necesita para avanzar sin esperar a nadie**: nombres, claves, formatos de mensajes, código compartido y qué necesita (o entrega) cada uno.

> **Regla de oro:** si dependes de algo que otro todavía no termina, **no esperes**. Usa el sustituto de la sección 7 y sigue avanzando. Lo que hay en este documento es el acuerdo: si alguien necesita cambiar un contrato, lo avisa al grupo primero.

---

## 1. Valores comunes

| Tema | Valor |
|---|---|
| Región | `us-east-1` |
| Stage de desarrollo | `dev` |
| Runtime | `python3.13` |
| Rol IAM | `arn:aws:iam::${aws:accountId}:role/LabRole` |
| Servicio (en `serverless.yml`) | `nubeduca-ms-<modulo>` → `usuarios`, `cursos`, `contenidos`, `evaluaciones`, `calificaciones`, `notificaciones` |
| Nombre de tablas | `${sls:stage}-t_<nombre>` |
| Nombre de topics SNS | `nubeduca-${sls:stage}-<evento>` |
| Nombre de colas SQS | `nubeduca-${sls:stage}-<modulo>-<evento>` |
| Tenants | `UTEC`, `UPC`, `PUCP` |
| Roles de usuario | `STUDENT`, `TEACHER`, `ADMIN` |
| Integración API Gateway | `integration: lambda` + `cors: true` (el body llega en `event['body']`) |
| Formato de respuesta | Éxito: `{"statusCode": 200, ...}` · Error: `{"statusCode": 400/403/404/500, "mensaje": "..."}` |
| Logs | `print(json.dumps({"tipo": "INFO" \| "ERROR", "log_datos": {...}}))` dentro de `try … except` |

---

## 2. Contrato del token (lo entrega el rol 1, lo usan todos)

### 2.1 Tabla `${sls:stage}-t_tokens_acceso` (en ms-usuarios)

Clave de partición: `token`.

```json
{
  "token": "6f1c2a9e-1b2c-4d5e-8f90-123456789abc",
  "tenant_id": "UTEC",
  "email": "docente.demo@utec.edu.pe",
  "rol": "TEACHER",
  "expires": "2026-11-14 18:30:00"
}
```

### 2.2 Lambda de validación

- Nombre: **`nubeduca-ms-usuarios-${sls:stage}-validar`** (función `validar` del servicio `nubeduca-ms-usuarios`).
- Entrada: `{"token": "..."}`
- Salida válida: `{"statusCode": 200, "tenant_id": "UTEC", "email": "...", "rol": "TEACHER"}`
- Salida inválida: `{"statusCode": 403, "mensaje": "Token no existe" | "Token expirado"}`

### 2.3 `validar_token.py` (cada rol 2–6 lo copia en su repo)

```python
import os
import json
import boto3

lambda_client = boto3.client('lambda')


def validar_token(event):
    # Modo desarrollo: sin validación, se usan los datos del body
    if os.environ.get('VALIDAR_TOKEN', 'true').lower() != 'true':
        body = event.get('body') or {}
        return {
            'statusCode': 200,
            'tenant_id': body.get('tenant_id', 'UTEC'),
            'email': body.get('email', 'docente.demo@utec.edu.pe'),
            'rol': body.get('rol', 'TEACHER')
        }

    token = (event.get('headers') or {}).get('Authorization')
    if not token:
        return {'statusCode': 403, 'mensaje': 'Falta el token'}

    respuesta = lambda_client.invoke(
        FunctionName=os.environ['VALIDAR_TOKEN_FUNCION'],
        InvocationType='RequestResponse',
        Payload=json.dumps({'token': token})
    )
    return json.loads(respuesta['Payload'].read())
```

Uso al inicio de cada Lambda protegida:

```python
usuario = validar_token(event)
if usuario['statusCode'] != 200:
    return {'statusCode': 403, 'mensaje': 'Forbidden - Acceso No Autorizado'}
tenant_id = usuario['tenant_id']   # el tenant SIEMPRE sale del token, nunca del body
email = usuario['email']
rol = usuario['rol']
```

### 2.4 En el `serverless.yml` de cada rol 2–6

```yaml
provider:
  environment:
    VALIDAR_TOKEN: "false"     # "true" cuando el rol 1 ya tenga desplegado ms-usuarios
    VALIDAR_TOKEN_FUNCION: nubeduca-ms-usuarios-${sls:stage}-validar
```

Para que el header `Authorization` llegue a la Lambda, cada endpoint protegido usa esta plantilla (igual que en el S10):

```yaml
      - http:
          path: /cursos/crear
          method: post
          cors: true
          integration: lambda
          request:
            template:
              application/json: |
                {
                  "method": "$context.httpMethod",
                  "path": "$context.path",
                  "headers": { "Authorization": "$input.params('Authorization')" },
                  "body": $input.body
                }
```

---

## 3. Contrato de eventos (SNS → SQS)

### 3.1 Los 5 eventos

| Evento | Topic SNS | Lo publica | Lo consume |
|---|---|---|---|
| Usuario registrado | `nubeduca-${sls:stage}-usuario-registrado` | Rol 1 | Rol 6 |
| Estudiante inscrito | `nubeduca-${sls:stage}-estudiante-inscrito` | Rol 2 | Rol 6 |
| Material publicado | `nubeduca-${sls:stage}-material-publicado` | Rol 3 | Rol 6 |
| Entrega enviada | `nubeduca-${sls:stage}-entrega-enviada` | Rol 4 | Rol 5 |
| Nota publicada | `nubeduca-${sls:stage}-nota-publicada` | Rol 5 | Rol 6 |

**Regla:** quien **publica** crea el topic en su `serverless.yml`. Quien **consume** crea su propia cola SQS y la suscripción al topic.

### 3.2 Formato de cada mensaje (JSON)

**`usuario-registrado`**
```json
{ "tenant_id": "UTEC", "email": "alumno.demo@utec.edu.pe", "nombre": "Ana Torres", "rol": "STUDENT", "fecha": "2026-11-05 09:00:00" }
```

**`estudiante-inscrito`**
```json
{ "tenant_id": "UTEC", "curso_id": "CUR-00025", "nombre_curso": "Cloud Computing", "email": "alumno.demo@utec.edu.pe", "fecha": "2026-11-05 09:10:00" }
```

**`material-publicado`**
```json
{ "tenant_id": "UTEC", "curso_id": "CUR-00025", "contenido_id": "CONT-00025", "titulo": "Semana 1 - Introducción a Serverless",
  "tipo": "ARCHIVO", "semana": 1, "publicado_por": "docente.demo@utec.edu.pe", "fecha": "2026-11-05 10:15:08" }
```

**`entrega-enviada`**
```json
{ "tenant_id": "UTEC", "curso_id": "CUR-00025", "evaluacion_id": "EVA-00025", "titulo": "Quiz 1 - Multi-tenancy",
  "email": "alumno.demo@utec.edu.pe", "tipo": "QUIZ", "respuestas": { "1": "B", "2": "D" }, "clave": { "1": "B", "2": "A" },
  "puntaje_max": 20, "fecha_entrega": "2026-11-12 21:10:00" }
```
(Para `TAREA`, `respuestas` y `clave` van como `null`, y se agregan `texto` y/o `enlace`.)

**`nota-publicada`**
```json
{ "tenant_id": "UTEC", "curso_id": "CUR-00025", "evaluacion_id": "EVA-00025", "titulo": "Quiz 1 - Multi-tenancy",
  "email": "alumno.demo@utec.edu.pe", "nota": 10, "puntaje_max": 20, "fecha": "2026-11-12 21:10:05" }
```

### 3.3 Cómo publicar (quien produce)

`serverless.yml`:
```yaml
provider:
  environment:
    TOPIC_MATERIAL_PUBLICADO: arn:aws:sns:${aws:region}:${aws:accountId}:nubeduca-${sls:stage}-material-publicado

resources:
  Resources:
    TopicMaterialPublicado:
      Type: AWS::SNS::Topic
      Properties:
        TopicName: nubeduca-${sls:stage}-material-publicado
```

Python:
```python
sns = boto3.client('sns')
sns.publish(TopicArn=os.environ['TOPIC_MATERIAL_PUBLICADO'], Message=json.dumps(mensaje, ensure_ascii=False))
```

### 3.4 Cómo consumir (quien escucha)

`serverless.yml` (ejemplo del rol 6 escuchando `material-publicado`):
```yaml
functions:
  avisar_material:
    handler: AvisarMaterial.lambda_handler
    events:
      - sqs:
          arn: !GetAtt ColaMaterialPublicado.Arn
          batchSize: 10

resources:
  Resources:
    ColaMaterialPublicado:
      Type: AWS::SQS::Queue
      Properties:
        QueueName: nubeduca-${sls:stage}-notificaciones-material-publicado

    SuscripcionMaterialPublicado:
      Type: AWS::SNS::Subscription
      Properties:
        TopicArn: arn:aws:sns:${aws:region}:${aws:accountId}:nubeduca-${sls:stage}-material-publicado
        Protocol: sqs
        Endpoint: !GetAtt ColaMaterialPublicado.Arn
        RawMessageDelivery: true      # el body de SQS es directamente el JSON del contrato

    PoliticaColaMaterialPublicado:
      Type: AWS::SQS::QueuePolicy
      Properties:
        Queues:
          - !Ref ColaMaterialPublicado
        PolicyDocument:
          Statement:
            - Effect: Allow
              Principal: { Service: sns.amazonaws.com }
              Action: sqs:SendMessage
              Resource: !GetAtt ColaMaterialPublicado.Arn
              Condition:
                ArnEquals:
                  aws:SourceArn: arn:aws:sns:${aws:region}:${aws:accountId}:nubeduca-${sls:stage}-material-publicado
```

Python:
```python
def lambda_handler(event, context):
    for record in event['Records']:
        mensaje = json.loads(record['body'])   # el JSON del contrato (gracias a RawMessageDelivery)
        tenant_id = mensaje['tenant_id']
        ...
```

### 3.5 Cómo probar sin esperar al otro rol

1. En **tu propia cuenta**, crea los topics que necesitas con el script `scripts/crear_topics_dev.sh` (antes de tu `sls deploy`).
2. Despliega tu microservicio.
3. Simula el evento:
```bash
aws sns publish \
  --topic-arn arn:aws:sns:us-east-1:<TU_CUENTA>:nubeduca-dev-material-publicado \
  --message '{"tenant_id":"UTEC","curso_id":"CUR-00025","contenido_id":"CONT-00025","titulo":"Prueba","tipo":"ARCHIVO","semana":1,"publicado_por":"docente.demo@utec.edu.pe","fecha":"2026-11-05 10:15:08"}'
```
4. Revisa en **CloudWatch** que tu Lambda recibió el mensaje.

⚠️ Los topics creados a mano **solo** se usan en tu cuenta de pruebas. En la cuenta del despliegue final los crea el `serverless.yml` de cada productor.

---

## 4. Tablas de cada microservicio

| Rol | Tabla | Clave de partición (HASH) | Clave de ordenamiento (RANGE) |
|---|---|---|---|
| 1 | `t_usuarios` | `tenant_id` | `email` |
| 1 | `t_tokens_acceso` | `token` | — |
| 2 | `t_cursos` | `tenant_id` | `curso_id` |
| 2 | `t_inscripciones` | `tenant_curso` (`UTEC#CUR-00025`) | `email` |
| 3 | `t_contenidos` | `tenant_curso` (`UTEC#CUR-00025`) | `contenido_id` |
| 4 | `t_evaluaciones` | `tenant_curso` (`UTEC#CUR-00025`) | `evaluacion_id` |
| 4 | `t_entregas` | `tenant_evaluacion` (`UTEC#EVA-00025`) | `email` |
| 5 | `t_calificaciones` | `tenant_curso` (`UTEC#CUR-00025`) | `email_evaluacion` (`alumno@utec.edu.pe#EVA-00025`) |
| 6 | `t_notificaciones` | `tenant_email` (`UTEC#alumno@utec.edu.pe`) | `fecha_id` (`2026-11-05 10:15:08#uuid`) |
| 6 | `t_destinatarios` | `tenant_curso` (`UTEC#CUR-00025`) | `email` |

Cada rol documenta la **estructura JSON completa** de sus tablas en el README de su repo.

---

## 5. Datos ficticios (30,000 por microservicio)

**10,000 registros por tenant** (`UTEC`, `UPC`, `PUCP`) en la tabla principal, con `boto3` + `table.batch_writer()`. Para que los datos se relacionen entre microservicios, todos usan los mismos IDs:

| Entidad | Patrón | Rango por tenant |
|---|---|---|
| Estudiantes | `estudiante{n}@{tenant en minúsculas}.edu.pe` | n = 1 … 9,000 |
| Docentes | `docente{n}@{tenant en minúsculas}.edu.pe` | n = 1 … 1,000 |
| Cursos | `CUR-{n:05d}` | n = 1 … 1,000 |
| Contenidos | `CONT-{n:05d}` | 10 por curso |
| Evaluaciones | `EVA-{n:05d}` | 10 por curso |

**Usuarios de la demo** (los crea el rol 1, contraseña acordada por el grupo):

| Tenant | Docente | Estudiante |
|---|---|---|
| UTEC | `docente.demo@utec.edu.pe` | `alumno.demo@utec.edu.pe` |
| UPC | `docente.demo@upc.edu.pe` | `alumno.demo@upc.edu.pe` |

**Curso de la demo:** `CUR-00001` en cada tenant.

---

## 6. Endpoints de cada microservicio (para el frontend)

Todos protegidos con `Authorization`, salvo registro y login.

| Rol | Endpoints |
|---|---|
| 1 | `POST /usuarios/registro` · `POST /usuarios/login` · `GET /usuarios/perfil` · `POST /usuarios/listar` |
| 2 | `POST /cursos/crear` · `POST /cursos/listar` · `POST /cursos/buscar` · `PUT /cursos/modificar` · `DELETE /cursos/eliminar` · `POST /cursos/inscribir` · `GET /cursos/mis-cursos` · `POST /cursos/inscritos` |
| 3 | `POST /contenidos/subir` · `POST /contenidos/crear-enlace` · `POST /contenidos/listar` · `POST /contenidos/descargar` · `DELETE /contenidos/eliminar` |
| 4 | `POST /evaluaciones/crear` · `POST /evaluaciones/listar` · `POST /evaluaciones/buscar` · `PUT /evaluaciones/modificar` · `DELETE /evaluaciones/eliminar` · `POST /evaluaciones/entregar` · `POST /evaluaciones/entregas` |
| 5 | `POST /calificaciones/calificar` · `GET /calificaciones/mis-notas` · `POST /calificaciones/progreso` · `POST /calificaciones/reporte-curso` |
| 6 | `GET /notificaciones/mias` · `PUT /notificaciones/marcar-leida` |

**Frontend:** las URLs base van en variables de entorno de Amplify: `VITE_API_USUARIOS`, `VITE_API_CURSOS`, `VITE_API_CONTENIDOS`, `VITE_API_EVALUACIONES`, `VITE_API_CALIFICACIONES`, `VITE_API_NOTIFICACIONES`.

Cada rol sube su colección de Postman a la carpeta `postman/` de su repo.

---

## 7. Dependencias por rol

### Rol 1 — Usuarios y acceso
| | |
|---|---|
| **Entrega a otros** | Lambda `validar` y `validar_token.py` (a todos) · topic `usuario-registrado` (rol 6) · base del frontend: layout, rutas, login y cliente de API (a todos) · usuarios demo |
| **Necesita de otros** | Nada para el backend. Para el frontend: las colecciones de Postman de cada rol |
| **Mientras tanto** | — (es el rol que no espera a nadie) |
| **Para el avance (30%)** | Registro, login y validar en Postman · 30k usuarios · frontend base en Amplify con login |

### Rol 2 — Cursos e inscripciones
| | |
|---|---|
| **Entrega a otros** | Topic `estudiante-inscrito` (rol 6) · IDs de cursos `CUR-xxxxx` (todos) · plantilla del informe |
| **Necesita de otros** | Token (rol 1) · base del frontend (rol 1) · secciones del informe (todos) |
| **Mientras tanto** | `VALIDAR_TOKEN=false` · pantallas con mocks |
| **Para el avance (30%)** | CRUD de cursos e inscripción en Postman · 30k cursos · pantalla de catálogo |

### Rol 3 — Contenidos (S3)
| | |
|---|---|
| **Entrega a otros** | Topic `material-publicado` (rol 6) · diagrama de arquitectura (todos) |
| **Necesita de otros** | Token (rol 1) · base del frontend (rol 1) · nombres de recursos de cada rol para el diagrama (están en este documento) |
| **Mientras tanto** | `VALIDAR_TOKEN=false` · pantallas con mocks |
| **Para el avance (30%)** | Subida con URL prefirmada + evento de S3 · 30k contenidos · diagrama v1 |

### Rol 4 — Evaluaciones y entregas
| | |
|---|---|
| **Entrega a otros** | Topic `entrega-enviada` (rol 5) · plantilla del PowerPoint |
| **Necesita de otros** | Token (rol 1) · base del frontend (rol 1) · diapositivas (todos) |
| **Mientras tanto** | `VALIDAR_TOKEN=false` · pantallas con mocks |
| **Para el avance (30%)** | Crear y listar evaluaciones (sin respuestas para el estudiante) · 30k evaluaciones · diapositivas del avance |

### Rol 5 — Calificaciones y seguimiento
| | |
|---|---|
| **Entrega a otros** | Topic `nota-publicada` (rol 6) · despliegue final · colección Postman unificada |
| **Necesita de otros** | Token (rol 1) · eventos `entrega-enviada` (rol 4) · repos terminados de todos (para el despliegue final) · base del frontend (rol 1) |
| **Mientras tanto** | `VALIDAR_TOKEN=false` · crear el topic `entrega-enviada` en su cuenta y simular entregas con `aws sns publish` |
| **Para el avance (30%)** | Calificar una tarea y reporte del curso · 30k calificaciones · pantalla de mis notas |

### Rol 6 — Notificaciones
| | |
|---|---|
| **Entrega a otros** | Topic `notificaciones` con emails · guion de la demo y video |
| **Necesita de otros** | Token (rol 1) · eventos de los roles 1, 2, 3 y 5 · base del frontend (rol 1) |
| **Mientras tanto** | `VALIDAR_TOKEN=false` · crear los 4 topics en su cuenta y simular los eventos con `aws sns publish` |
| **Para el avance (30%)** | Recibir un evento simulado y que llegue el email · 30k notificaciones · bandeja de notificaciones |

### Resumen de quién depende de quién

| ↓ necesita de → | Rol 1 | Rol 2 | Rol 3 | Rol 4 | Rol 5 | Rol 6 |
|---|---|---|---|---|---|---|
| **Rol 1** | — | | | | | |
| **Rol 2** | token, frontend base | — | | | | |
| **Rol 3** | token, frontend base | | — | | | |
| **Rol 4** | token, frontend base | | | — | | |
| **Rol 5** | token, frontend base | | | `entrega-enviada` | — | |
| **Rol 6** | token, frontend base, `usuario-registrado` | `estudiante-inscrito` | `material-publicado` | | `nota-publicada` | — |

Todas las dependencias tienen un sustituto (columna "Mientras tanto"), así que **ninguna bloquea el avance**.

---

## 8. Despliegue final (en una sola cuenta)

Las Lambdas se invocan entre sí y los topics y colas deben estar en la misma cuenta, por eso al final todo se despliega en **una sola cuenta** (la del rol 5), en este orden:

1. `nubeduca-ms-usuarios`
2. `nubeduca-ms-cursos`
3. `nubeduca-ms-contenidos`
4. `nubeduca-ms-evaluaciones`
5. `nubeduca-ms-calificaciones`
6. `nubeduca-ms-notificaciones`
7. `nubeduca-frontend` (Amplify, con las URLs finales)

Como todo usa `${aws:accountId}` y nombres fijos, basta con clonar los repos y hacer `sls deploy` en ese orden (cambiando solo el `org:` de Serverless).

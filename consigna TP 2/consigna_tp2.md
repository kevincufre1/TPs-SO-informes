# Capítulo 2 · Registro Central NEXUS

## El sector ya existe. Ahora tiene que registrar.

NEXUS-9 tiene dos máquinas, usuarios y acceso remoto, pero todavía no guarda nada. En este capítulo construirán la aplicación del sector y la pondrán a correr como un servicio real del sistema operativo: algo que arranca solo, sobrevive a un reinicio y no depende de que alguien tenga una terminal abierta.

---

## 🎯 La misión

Construir `nexusd`: una aplicación modular en C17 que registre unidades, operadores e incidentes, los persista en SQLite y los exponga mediante una API HTTP.

Al finalizar, un operador deberá poder sentarse en `field-terminal` y consultar el estado del sector sin iniciar sesión en el servidor.

> **Importante:** este capítulo se construye sobre el anterior. Las mismas máquinas, el mismo repositorio y los usuarios de servicio que dejaron preparados en el Capítulo 1. No se crea nada desde cero.

---

## 🎯 Objetivo

Desarrollar una aplicación de sistema en C, con persistencia propia y una interfaz de red, e integrarla al ciclo de vida del sistema operativo que la aloja.

Al finalizar deberán poder demostrar que la aplicación arranca junto con el servidor, responde consultas desde otra máquina, conserva sus datos después de un reinicio, se detiene sin corromper nada y deja rastro de lo que hizo. Además, deberán poder explicar qué parte de ese comportamiento es responsabilidad del programa y qué parte es responsabilidad del sistema operativo.

---

## 📋 Demostración del capítulo

La evaluación incluirá una demostración técnica en tiempo real, con el servicio corriendo y ambas máquinas encendidas.

- **Servicio:** `nexusd` corriendo bajo systemd, iniciado automáticamente y ejecutándose con el usuario `nexus`.
- **API:** alta de una unidad, alta de un operador, creación de un incidente y cambio de su estado.
- **Persistencia:** reiniciar el servidor y comprobar que la información sigue estando.
- **Cliente remoto:** ejecutar `nexus-client.sh` desde `field-terminal` y explicar cómo llega hasta la aplicación.
- **Señales y logs:** detener el servicio de forma controlada y mostrar el rastro del cierre con `journalctl`. Podrá solicitarse una recarga de configuración.
- **Errores:** enviar una petición con datos faltantes o JSON inválido y explicar qué responde la API y por qué ese código.

---

## ✅ Criterios de aceptación

El capítulo se considerará técnicamente completo cuando se cumplan simultáneamente las siguientes condiciones:

- **Servicio.** `nexusd` funciona como servicio de systemd y no se ejecuta como `root`.
- **Persistencia.** Los datos sobreviven a un reinicio y el cierre del servicio no corrompe la base.
- **API.** Los endpoints mínimos responden en JSON, con códigos HTTP consistentes y errores descriptivos.
- **Cliente remoto.** `field-terminal` consume correctamente la API mediante `nexus-client.sh`.
- **Observabilidad.** Los logs pueden consultarse con `journalctl` y la auditoría registra las acciones relevantes.
- **Pruebas.** Las pruebas con CMocka son reproducibles y cubren los casos mínimos exigidos.

---

## Etapa 01 — Arquitectura de la aplicación

La aplicación se denominará `nexusd` y deberá organizarse en módulos con responsabilidades diferenciadas. Cada módulo deberá exponer una interfaz explícita: ningún módulo podrá acceder directamente a las estructuras internas de otro.

| Módulo | Responsabilidad |
|---|---|
| `registry` | Gestión de unidades y operadores |
| `incidents` | Creación, consulta y actualización de incidentes |
| `evidence` | Validación y asociación de evidencias |
| `notifications` | Generación de solicitudes de notificación |
| `audit` | Registro de acciones relevantes |
| `storage` | Acceso a SQLite |
| `api` | Exposición de operaciones mediante HTTP |
| `config` | Lectura y validación de configuración |
| `logging` | Registro uniforme de mensajes y errores |

### 🔍 Preguntas de investigación

- ¿Qué diferencia hay entre un programa y un servicio del sistema?
- ¿Qué significa que un proceso no dependa de una sesión interactiva?

La separación de módulos no es una formalidad: es lo que permitirá, al final de la materia, documentar cómo cada uno podría convertirse en un servicio independiente.

---

## Etapa 02 — Persistencia

Toda la información del sector deberá persistirse en SQLite. Deberán modelar como mínimo las siguientes entidades, con los campos indicados.

### 🚗 Unidad

```
id · designation · model · status · sector · created_at
```

### 👤 Operador

```
id · name · clearance_level · active · created_at
```

### 🚨 Incidente

```
id · unit_id · operator_id · severity · description · status · created_at · updated_at
```

La severidad deberá contemplar al menos `low`, `medium`, `high` y `critical`. El estado, al menos `open`, `investigating`, `resolved` y `closed`.

### 🔗 Evidencia

```
id · incident_id · filename · checksum · uploaded_at
```

### 📕 Evento de auditoría

```
id · actor · action · resource · result · timestamp
```

### Lo que la base tiene que garantizar

Los datos recibidos deberán validarse **antes** de persistirse. La información deberá sobrevivir tanto al reinicio de la aplicación como al del servidor. Y cada vez que se cree o modifique un recurso relevante, deberá quedar registrada una entrada de auditoría.

### 🔍 Preguntas de investigación

- ¿Qué significa que SQLite sea una base embebida? ¿Dónde corre realmente?
- ¿Qué pasa si dos partes del programa escriben al mismo tiempo?
- ¿Qué es una transacción y cuándo conviene usar una?
- ¿Qué diferencia hay entre que una escritura "retorne" y que esté efectivamente en disco?
- ¿Qué puede salir mal si el proceso termina en medio de una escritura?

---

## Etapa 03 — La API del sector

La aplicación deberá publicar una API versionada bajo `/api/v1/` e implementar como mínimo:

```
GET /health
GET /api/v1/units
POST /api/v1/units
GET /api/v1/operators
POST /api/v1/operators
POST /api/v1/incidents
PATCH /api/v1/incidents/{id}
```

Las respuestas deberán utilizar JSON. Los errores deberán incluir un código y una descripción comprensible, y los códigos HTTP deberán ser consistentes con el resultado real de la operación. El endpoint `/health` deberá indicar si la aplicación **y** la base de datos están disponibles.

### 🔍 Preguntas de investigación

- ¿Qué códigos HTTP corresponden a: recurso creado, dato inválido, recurso inexistente y error interno?
- ¿Por qué `PATCH` y no `POST` para cambiar el estado de un incidente?
- ¿Para qué sirve versionar una API bajo `/api/v1/`?

> **La API no se expone todavía.** En este capítulo `nexusd` escucha únicamente en `127.0.0.1`. En el Capítulo 3, Nginx será el único servicio accesible desde afuera. Tengan esto presente al probar desde `field-terminal`.

---

## Etapa 04 — Configuración externa

La aplicación deberá leer su configuración desde:

```
/etc/nexus/nexus.conf
```

**No se deberán codificar rutas, puertos ni credenciales en el código fuente.** La configuración deberá contemplar como mínimo:

```
listen_address=127.0.0.1
listen_port=8080
database_path=/var/lib/nexus/nexus.db
evidence_path=/var/lib/nexus/evidence
log_level=info
```

### 🔍 Preguntas de investigación

- ¿Qué debería hacer el programa si el archivo no existe? ¿Y si existe pero tiene una línea inválida?
- ¿Conviene arrancar con valores por defecto o negarse a arrancar?
- ¿Qué permisos debería tener un archivo de configuración de un servicio del sistema?
- ¿Por qué `/etc` y no el directorio del programa?
- ¿Qué parte de la configuración tiene sentido poder recargar sin reiniciar el proceso?

---

## Etapa 05 — Señales y ciclo de vida

Un servicio no decide cuándo termina: se lo avisan. La aplicación deberá manejar correctamente:

```
SIGTERM
SIGINT
SIGHUP
```

Ante una señal de terminación deberá cerrar conexiones, liberar recursos y finalizar las operaciones pendientes. Ante `SIGHUP` deberá recargar, cuando sea posible, la configuración sin reiniciar completamente el proceso.

### 🔍 Preguntas de investigación

- ¿Qué operaciones son seguras dentro de un manejador de señales? Investiguen `signal-safety(7)`.
- ¿Por qué un manejador suele limitarse a levantar una bandera en lugar de hacer el trabajo?
- ¿Qué pasa con una escritura a la base si el proceso muere en el medio?
- ¿Por qué `SIGHUP` se usa históricamente para recargar configuración?

> **Criterio de la cátedra:** un cierre que corrompe la base es un cierre fallido, aunque el proceso haya terminado con código 0.

---

## Etapa 06 — nexusd como servicio

La aplicación deberá instalarse y ejecutarse como una unidad de systemd:

```
nexus.service
```

Deberá ejecutarse con un usuario dedicado llamado `nexus` y **nunca como root**. La unidad deberá contemplar:

- Usuario y grupo propios.
- Reinicio ante fallo.
- Directorio de trabajo.
- Archivo de configuración.
- Dependencia de red.
- Cierre controlado.
- Variables de entorno mínimas.

Los eventos del servicio deberán registrarse mediante journald y ser consultables con `journalctl`.

### 🔍 Preguntas de investigación

- ¿Qué hace systemd cuando ejecuta `systemctl start`?
- ¿Qué significan los distintos valores de `Type=` en una unidad?
- ¿Qué diferencia hay entre `Restart=always` y `Restart=on-failure`?
- ¿Qué quiere decir que una unidad dependa de la red? ¿Alcanza con `After=`?
- ¿Cómo decide systemd que un servicio "falló"? ¿Qué rol juega el código de salida?
- ¿Dónde van a parar los mensajes que el programa escribe por salida estándar?
- ¿Qué significa habilitar un servicio y en qué se diferencia de iniciarlo?
- ¿Qué directivas permiten limitar qué puede hacer el proceso sobre el sistema?

---

## Etapa 07 — Cliente remoto

Deberán implementar un cliente Bash ejecutable desde `field-terminal`:

```
nexus-client.sh
```

Deberá permitir, como mínimo, las siguientes operaciones:

```
health
list-units
create-unit
list-operators
create-operator
list-incidents
create-incident
update-incident
```

Valen las mismas reglas de Bash del Capítulo 1: validar argumentos, citar correctamente las variables, usar códigos de salida significativos, limpiar archivos temporales y superar `shellcheck`.

### 🔍 Preguntas de investigación

- ¿Cómo distingue `curl` entre un fallo de red y una respuesta HTTP de error?
- ¿Cómo se obtiene el código de estado HTTP desde un script?
- ¿Qué debería devolver el cliente si la API responde 404? ¿Y si no responde?
- ¿Cómo se arma un cuerpo JSON desde Bash sin romperlo con comillas o espacios?
- Recordando que `nexusd` escucha en `127.0.0.1`: ¿cómo llega el cliente desde la otra máquina en esta etapa?

---

## Etapa 08 — Pruebas

Deberán ejecutar pruebas unitarias y de integración con CMocka, reproducibles mediante un único comando y verificadas por la integración continua. Como mínimo deberán cubrir:

- **Inserción válida.** Un alta correcta queda persistida y es recuperable.
- **Datos obligatorios faltantes.** La operación se rechaza y nada queda a medio escribir.
- **Identificador inexistente.** La consulta de un recurso que no existe no se distingue de un error interno.
- **Error de SQLite.** La aplicación reacciona ante una falla de la base sin terminar de manera descontrolada.
- **JSON inválido.** Una entrada malformada produce un error descriptivo, no una caída.
- **Cierre mediante señal.** El proceso termina de forma ordenada y la base queda consistente.
- **Health check.** `/health` refleja el estado real de la aplicación y de la base.

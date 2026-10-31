# Capítulo 3 · Sector en Producción

## El sector tiene que sobrevivir solo.

NEXUS-9 registra incidentes, pero hoy depende de que nadie lo toque: la API está expuesta sin protección, cualquiera puede alcanzar el puerto interno, no hay copias de la información y si el proceso muere, muere. En este capítulo final convertirán la aplicación en un sistema publicado, protegido y recuperable.

---

## 🎯 La misión

Publicar la API detrás de Nginx con TLS, cerrar todo lo que no deba estar abierto, habilitar la transferencia de evidencias, y dejar el sector preparado para seguir funcionando cuando algo falle.

Hasta ahora trabajaron sobre un sistema que funciona cuando todo sale bien. Este capítulo trata de lo otro: qué pasa cuando el proceso muere, cuando se borra la base, cuando alguien intenta conectarse a un puerto que no debería estar abierto o cuando el disco se llena de logs. Cada etapa agrega un mecanismo del sistema operativo que responde a una de esas situaciones.

Al finalizar, un operador deberá poder trabajar desde `field-terminal` contra un sistema que se recupera por sí mismo, conserva copias verificables de su información y puede diagnosticarse cuando algo se rompe.

> **Importante:** este es el último capítulo del proyecto. Todo lo construido en los anteriores entra en la evaluación final: las máquinas, los usuarios, la aplicación, la base de datos y los scripts. Nada se reemplaza, todo se protege.

---

## 🧭 Objetivo

Integrar la aplicación con los servicios de seguridad, continuidad y operación del sistema operativo que la aloja, hasta obtener un sistema que una persona distinta del equipo pueda instalar, operar y recuperar siguiendo la documentación.

Al finalizar deberán poder demostrar que la API sólo se alcanza por HTTPS, que el puerto interno es inaccesible, que una evidencia transferida queda asociada y verificada, que el servicio se recupera ante una caída, que la información se puede restaurar desde una copia y que todo el sistema se instala con un único comando. Y, sobre todo, deberán poder explicar qué mecanismo del sistema operativo hace posible cada una de esas cosas.

---

## 📦 Qué hay que entregar

Antes de empezar, el panorama completo. Al cerrar el capítulo tienen que existir estos artefactos, todos versionados en el repositorio salvo donde se indique lo contrario.

### ⚙️ Configuración del sistema

- **Sitio de Nginx:** El bloque de servidor que atiende por HTTPS y reenvía a la aplicación, más el que decide qué hacer con el tráfico que llega sin cifrar.
- **Material de la autoridad certificante:** La clave y el certificado raíz del laboratorio, y el certificado firmado para `sector-core`. En el repositorio va el procedimiento para generarlos; los archivos con claves, no.
- **Reglas de firewall de ambas máquinas:** Guardadas de forma que puedan reaplicarse desde cero en una instalación limpia, no sólo tipeadas una vez en la terminal.
- **Configuración de SSH para evidencias:** El fragmento que limita al usuario de carga a SFTP y lo encierra en su directorio, sin afectar el acceso administrativo normal.
- **Postfix con entrega local:** Los parámetros mínimos para que un mensaje generado por la aplicación llegue a un buzón dentro de la misma máquina.
- **Reglas de rotación de logs:** Cada cuánto rotan los logs de la aplicación, cuántos se conservan y qué se hace con los viejos.

### ⚡ Unidades de systemd

- **`nexus.service`:** La unidad del capítulo anterior, ahora con reinicio automático, límites de recursos y restricciones sobre dónde puede escribir el proceso.
- **`nexus-backup.service`:** La unidad que ejecuta una copia de seguridad y termina. No queda corriendo: hace su trabajo y sale.
- **`nexus-backup.timer`:** El temporizador que dispara la unidad anterior según la periodicidad que definan.

### 📟 Scripts Bash

- **`upload-evidence.sh`:** Transfiere un archivo al servidor y lo registra como evidencia de un incidente.
- **`backup.sh`:** Genera una copia verificable de toda la información del sector.
- **`restore.sh`:** Recupera la información a partir de una copia, validándola antes de tocar nada.
- **`health-check.sh`:** Responde si el sector está sano, con un código de salida que lo refleje.
- **`collect-diagnostics.sh`:** Captura el estado del sistema en el momento de una falla, para analizarlo después.
- **`deploy.sh`:** Instala o actualiza el sector completo y vuelve atrás si el resultado no funciona.

### 💻 Código

- **El cliente `nexusctl`:** Escrito en C sobre libcurl, compilado por el mismo build del proyecto.

### 📄 Documentación

- **Reglas de firewall y su justificación:** Qué se permite en cada máquina y por qué. Una lista de reglas sin motivo no se puede revisar ni mantener.
- **Denegaciones de SELinux:** Cada una con tres datos: qué operación fue bloqueada, sobre qué recurso, y cómo la resolvieron.
- **Política de retención de backups:** Cada cuánto se hace una copia, cuántas se conservan y con qué criterio se descartan las viejas.
- **Procedimiento de restauración:** Los pasos exactos para recuperar el sistema. Es el documento que van a seguir durante la demostración final, así que tiene que estar completo.
- **Documento de migración:** El análisis de cierre sobre cómo evolucionaría el sistema hacia servicios separados.

> ⚠️ **Advertencia de seguridad sobre claves:**  
> **Las claves privadas no se versionan.** Ni la de la CA, ni la del certificado del servidor, ni ninguna clave SSH. En el repositorio va el procedimiento para generarlas, no el resultado. Verifiquen que `.gitignore` las cubra antes del primer commit de este capítulo.

---

## Etapa 01 — Publicación con Nginx y TLS

Hasta ahora, para que `field-terminal` consumiera la API, o bien `nexusd` tenía que escuchar donde no debería, o había que entrar por SSH y probar desde adentro. Ninguna de las dos cosas sirve en un sistema publicado.

A partir de este capítulo el sector tiene **un único punto de entrada**: Nginx, por HTTPS. La aplicación no cambia de lugar — sigue escuchando donde siempre, en una interfaz local. Lo que cambia es quién puede hablarle.

```
field-terminal ——HTTPS——> Nginx ——local——> nexusd
```

### 💻 Reverse proxy

Nginx deberá recibir las peticiones de los operadores y reenviarlas a la aplicación, que seguirá escuchando únicamente en una interfaz local. El puerto interno de `nexusd` no deberá ser accesible de forma directa desde `field-terminal`.

Las solicitudes que lleguen por HTTP deberán rechazarse o redirigirse a HTTPS: no puede quedar una vía de acceso sin cifrar.

Deberán configurar además un límite de tamaño para el cuerpo de las peticiones y tiempos de espera para la comunicación con la aplicación. Elijan valores concretos y justifíquenlos en la documentación: el objetivo es que una petición enorme o una aplicación colgada no dejen a Nginx esperando para siempre.

### 🔐 Certificados

El laboratorio no tiene un certificado emitido por una autoridad pública, así que van a crear la suya. Eso implica tres cosas distintas que conviene no confundir:

1. **Una autoridad certificante del laboratorio**, con su propia clave y su certificado raíz.
2. **Un certificado para `sector-core`**, firmado por esa autoridad, que instala Nginx.
3. **El certificado de la autoridad instalado en `field-terminal`**, para que Rocky sepa en quién confiar.

Con las tres piezas en su lugar, la verificación desde Rocky tiene que funcionar sola.

> **Criterio de la cátedra:** si la demostración necesita `--insecure` o `-k` para funcionar, el certificado no está bien instalado. Ese flag no se usa en este capítulo. Tampoco sirve agregar el certificado del servidor directamente: lo que se instala en el cliente es el de la autoridad.

### ✅ Se considera cumplido cuando

- Desde `field-terminal`, una petición HTTPS a la API responde correctamente y el certificado valida sin flags adicionales.
- Un intento de conexión al puerto interno de `nexusd` desde `field-terminal` no prospera.
- Una petición por HTTP termina en HTTPS o es rechazada.
- Pueden mostrar qué proceso está escuchando en cada puerto y en qué interfaz.

### 🔎 Preguntas de investigación

- ¿Qué problema resuelve un reverse proxy que no resuelve publicar la aplicación directamente?
- ¿Qué significa que un certificado sea "válido"? ¿Quién decide eso?
- ¿Qué papel cumple una CA y por qué hay que instalarla en el cliente?
- ¿Qué diferencia hay entre el certificado del servidor y la clave privada que lo acompaña?
- ¿Por qué el nombre con el que se conecta el cliente tiene que coincidir con el del certificado?
- ¿Qué ocurre exactamente cuando se usa `--insecure`? ¿Qué deja de verificarse?
- Si Nginx termina el TLS, ¿qué viaja entre Nginx y la aplicación? ¿Es un problema en este escenario?
- ¿Cómo sabe la aplicación desde qué dirección vino realmente la petición, si todas le llegan desde Nginx?

---

## Etapa 02 — Firewall y aislamiento

Nginx decide qué se publica; el firewall decide quién puede siquiera intentarlo. Son dos controles distintos y hacen falta los dos: si mañana alguien configura mal un servicio y lo deja escuchando en todas las interfaces, el firewall es lo único que queda en el medio.

En ambas máquinas la política es la misma: permitir explícitamente lo necesario y rechazar el resto. Las reglas tienen que sobrevivir a un reinicio y quedar documentadas con su motivo, no sólo listadas.

### 🖥️ `sector-core` · Ubuntu Server

Permitir el acceso SSH administrativo, el tráfico HTTPS de la API y la transferencia de evidencias. Bloquear el puerto interno de `nexusd`.

Presten atención a un detalle: la transferencia de evidencias viaja sobre SSH. Averigüen si eso requiere abrir algo adicional o no, y documenten la conclusión.

### 🪐 `field-terminal` · Rocky Linux

Utilizar `firewalld`. Esta máquina es un cliente: casi no necesita aceptar conexiones entrantes. Permitan únicamente lo que realmente haga falta y documenten las reglas aplicadas, incluyendo la zona utilizada.

### 🛡️ SELinux

En Rocky Linux, SELinux deberá permanecer en modo **enforcing** durante todo el capítulo. Es muy probable que aparezcan denegaciones mientras configuran el acceso a la API o la carga de evidencias: eso es parte del ejercicio, no un obstáculo.

Cuando aparezca una denegación, el trabajo es: encontrar dónde quedó registrada, entender qué operación fue bloqueada y sobre qué recurso, y resolverla mediante el permiso, el contexto o la política apropiada. Cada denegación que hayan resuelto tiene que quedar documentada con esos tres datos.

> **Importante:**  
> **No se aceptará `setenforce 0` como solución.** Desactivar SELinux no resuelve el problema: lo oculta. Se evaluará que puedan leer una denegación, entender qué la provocó y corregirla.

### ✅ Se considera cumplido cuando

- Las reglas de ambas máquinas están activas después de un reinicio.
- Desde `field-terminal`, los servicios permitidos responden y los demás no.
- SELinux reporta modo enforcing en Rocky Linux.
- Pueden mostrar al menos una denegación que hayan encontrado y explicar cómo la resolvieron.

### 🔎 Preguntas de investigación

- ¿Qué diferencia hay entre rechazar y descartar una conexión? ¿Qué ve el cliente en cada caso?
- ¿Cómo se comprueba qué puertos están realmente en escucha y en qué interfaz?
- Si `nexusd` ya escucha sólo en loopback, ¿para qué sirve además bloquear su puerto en el firewall?
- ¿Qué agrega SELinux por encima de los permisos tradicionales de Linux?
- ¿Qué es un contexto de seguridad y dónde se ve?
- ¿Dónde quedan registradas las denegaciones y cómo se interpretan?
- ¿Qué diferencia hay entre activar un booleano de SELinux y cambiar el contexto de un archivo? ¿Cuándo corresponde cada uno?

---

## Etapa 03 — Evidencias y notificaciones

Un incidente sin respaldo es la palabra de un operador. El sector necesita poder adjuntar archivos a un incidente y demostrar después que ese archivo es el mismo que se cargó.

La transferencia y el registro van por caminos separados: **el archivo viaja por SFTP y la API sólo guarda sus metadatos.** Esto evita introducir carga de archivos por HTTP y mantiene el foco en los servicios del sistema operativo, que es de lo que trata la materia.

### 👤 Usuario de carga

Deberán configurar un usuario restringido, dedicado exclusivamente a recibir evidencias:

```
nexus_evidence
```

Este usuario **no deberá disponer de una shell interactiva**: si alguien obtiene sus credenciales, no debe poder ejecutar comandos en `sector-core`. Y sólo podrá escribir dentro de:

```
/var/lib/nexus/evidence/incoming/
```

Encerrar a un usuario en un directorio tiene requisitos propios sobre quién es el dueño de ese directorio y qué permisos tiene. Si la configuración parece correcta y la conexión igual falla, ese suele ser el motivo.

### 🔄 Flujo de evidencia

La secuencia completa, de punta a punta:

1. **El operador crea un incidente:** Primero tiene que existir aquello a lo que se va a adjuntar la evidencia. Un archivo suelto en el servidor no es evidencia de nada.
2. **Carga un archivo mediante SFTP:** El archivo viaja por fuera de la API, con el usuario restringido, y queda depositado en el directorio de carga.
3. **Ejecuta un comando de registro:** Recién en este punto la aplicación se entera de que el archivo existe. Hasta acá, para el sistema, no pasó nada.
4. **La aplicación calcula o valida su checksum:** Comprueba que el archivo esté realmente en el directorio y que su contenido coincida con lo declarado.
5. **Los metadatos quedan asociados al incidente:** Nombre, checksum y fecha se guardan en la base. El archivo en sí no entra a la base: sigue en el sistema de archivos.
6. **La acción se registra en auditoría:** Queda asentado quién hizo qué, sobre qué recurso y con qué resultado.

Antes de asociar una evidencia, el sistema deberá verificar que el archivo exista realmente en el directorio de carga: no alcanza con que alguien diga que lo subió. Cada evidencia deberá registrar un checksum SHA-256, y una discrepancia entre el checksum calculado y el informado tiene que impedir la asociación.

### 📫 Notificaciones internas

Deberán configurar un servicio de correo interno mediante Postfix, con **entrega local únicamente**: el correo nunca sale del laboratorio y no hace falta configurar envío hacia Internet.

Cuando se cree un incidente con severidad `critical`, el sistema deberá generar una notificación dirigida al buzón operativo. El resultado del intento —se haya entregado o no— deberá quedar registrado: una notificación que falla en silencio es peor que no tener notificaciones.

### 📜 Script de carga

Todo el flujo anterior tiene que poder ejecutarse con un solo comando desde `field-terminal`:

```
upload-evidence.sh
```

- **Validar argumentos:** Necesita saber a qué incidente se asocia el archivo y cuál es el archivo. Si falta alguno de los dos, no tiene sentido abrir una conexión.
- **Verificar que el archivo exista:** Y que sea legible, antes de intentar transferirlo. Fallar temprano evita dejar el sistema a medio camino.
- **Calcular SHA-256:** En origen, antes de enviar. Ese valor es el que después permite comprobar que lo que llegó es lo que salió.
- **Transferir mediante SFTP:** Con el usuario restringido, hacia el directorio de carga.
- **Registrar el archivo mediante la API:** Enviando el nombre y el checksum para que la aplicación lo asocie al incidente.
- **Limpiar archivos temporales:** Pase lo que pase, incluso si el script falla en la mitad. Acá es donde sirve un `trap`.
- **Informar errores claramente:** Distinguiendo situaciones que son muy distintas: "no pude transferir el archivo" deja el sistema como estaba; "transferí pero no pude registrarlo" deja un archivo huérfano en el servidor.

### ✅ Se considera cumplido cuando

- El usuario `nexus_evidence` no puede obtener una shell en `sector-core`.
- Tampoco puede escribir fuera del directorio de carga.
- Una evidencia transferida queda asociada a su incidente, con checksum registrado.
- Intentar asociar un archivo inexistente falla con un error comprensible.
- Crear un incidente crítico deja una notificación en el buzón operativo y una entrada en auditoría.

### 🔎 Preguntas de investigación

- ¿Cómo se restringe una cuenta a SFTP sin permitirle una shell?
- ¿Qué significa encerrar a un usuario en un directorio y qué condiciones debe cumplir ese directorio?
- ¿Por qué un usuario de servicio no debería poder iniciar sesión normalmente?
- ¿Para qué sirve el checksum si el archivo ya llegó completo?
- ¿Qué debería pasar si el checksum calculado no coincide con el registrado?
- ¿Quién debería ser el dueño del archivo una vez cargado, y con qué permisos?
- ¿Qué información mínima necesita la auditoría para que la acción sea reconstruible después?

---

## Etapa 04 — Resiliencia, límites de recursos y rotación de logs

> **Nota de correlación:** Esta etapa integra los requisitos de resiliencia del servicio (`nexus.service`), confinamiento estricto de recursos y preservación del almacenamiento mediante rotación de logs, requeridos para el criterio de aceptación de *Continuidad* y la dimensión *Resiliencia y límites de systemd* (15% de la rúbrica).

Para garantizar la estabilidad operacional continua de `sector-core`, el servicio `nexusd` no puede correr de forma ilimitada ni dejar que el sistema operativo se degrade ante anomalías o consumo desmedido.

### ⚡ Endurecimiento y límites en `nexus.service`

La unidad de systemd `nexus.service` construida en el Capítulo 2 debe evolucionar incorporando políticas de supervisión activa y gobernanza de recursos (`systemd.resource-control(5)`):

- **Reinicio automático:** Política ante caídas anómalas (`Restart=on-failure`, tiempos de gracia `RestartSec=`).
- **Límites de memoria:** Tope de consumo de memoria física mediante directivas como `MemoryMax=` o `MemoryHigh=` para evitar que una fuga o saturación degrade al resto del sistema anfitrión.
- **Límites de CPU y tareas:** Restricciones de cuota de tiempo de procesador (`CPUQuota=`) y límite de procesos/hilos hijos (`TasksMax=`).
- **Confinamiento estricto del sistema de archivos:** Restricciones de escritura exclusivas sobre sus rutas autorizadas (`ReadWritePaths=/var/lib/nexus`, `ReadOnlyPaths=/etc/nexus`, `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`).

### 🔄 Rotación de logs con `logrotate`

Un daemon en producción genera trazas continuas. Si los logs crecen sin control, terminan agotando el espacio en disco, comprometiendo a SQLite y los backups:

- Configurar directivas en `/etc/logrotate.d/` para los registros de la aplicación.
- Definir periodicidad de rotación (diaria/semanal), compresión (`compress`, `delaycompress`), cantidad de generaciones a conservar (`rotate N`) y eliminación segura de registros antiguos.
- Asegurar que el proceso reabra sus descriptores o continúe escribiendo sin interrupciones tras la rotación (mediante directivas de post-rotación o señales POSIX correspondientes).

### ✅ Se considera cumplido cuando

- Si el proceso de `nexusd` muere de forma forzada (`kill -9`), systemd lo detecta y lo reinicia automáticamente.
- Los límites de recursos (memoria, CPU, tareas) se encuentran formalmente configurados e inspeccionables con `systemctl show nexus.service`.
- La configuración de `logrotate` valida correctamente con `logrotate -d` y rota los logs sin corromper trazas ni interrumpir la observabilidad en journald.

---

## Etapa 05 — Backups y restauración

De todo lo que construyeron en el cuatrimestre, lo único verdaderamente irremplazable es la información: el binario se vuelve a compilar y la configuración se vuelve a escribir, pero los incidentes y las evidencias no. Esta etapa trata de eso.

### 💾 El backup

```
backup.sh
```

Cada copia deberá incluir:

- **La base SQLite en un estado consistente:** El contenido de la base en un punto exacto del tiempo, sin transacciones a medio escribir. Esta es la parte delicada y la que no se resuelve copiando el archivo.
- **El archivo de configuración:** Para poder reconstruir el servicio tal como estaba, y no como está hoy el que escriban de memoria.
- **Las evidencias almacenadas:** Los archivos en sí. La base guarda sólo sus metadatos: si se pierden los archivos, los incidentes quedan con referencias a nada.
- **Un manifest con fecha y checksums:** La lista de todo lo que contiene la copia, con el checksum de cada pieza. Es lo que convierte un directorio de archivos en un backup verificable.

El manifest es la pieza que convierte un directorio de archivos en un backup: tiene que permitir verificar que la copia está completa e intacta **sin necesidad de restaurarla**. Piensen qué datos necesita para eso.

Las copias se almacenarán en:

```
/var/backups/nexus/
```

Hay un detalle que no es obvio: copiar el archivo de la base mientras la aplicación está corriendo no garantiza una copia consistente. Investiguen qué mecanismos ofrece SQLite para esto y decidan si necesitan detener el servicio o no.

### ♻️ La restauración

```
restore.sh
```

La restauración deberá **validar la integridad del backup antes de reemplazar información**. El orden importa: si primero borran lo que hay y después descubren que la copia estaba corrupta, perdieron las dos cosas.

Documenten el procedimiento completo, incluido qué hay que hacer con el servicio antes y después. Ese documento es lo que van a seguir durante la demostración final.

### ⏰ Automatización

Un backup que depende de que alguien se acuerde de ejecutarlo no es un backup. Deberán crear:

```
nexus-backup.service
nexus-backup.timer
```

El timer deberá ejecutar backups periódicos y eliminar copias antiguas según una política de retención documentada: cada cuánto se hace una copia, cuántas se conservan y con qué criterio se descartan.

### ✅ Se considera cumplido cuando

- Un backup se puede verificar sin restaurarlo.
- Restaurar sobre una base eliminada recupera unidades, incidentes y evidencias.
- Un backup dañado es rechazado por `restore.sh` sin tocar la información existente.
- El timer está activo y puede consultarse cuándo se ejecuta la próxima vez.
- Las copias antiguas se eliminan solas según la política documentada.

### 🔎 Preguntas de investigación

- ¿Qué significa que una base SQLite esté en un estado "consistente"? ¿Alcanza con copiar el archivo mientras la aplicación corre?
- ¿Qué debería contener el manifest para que el backup sea verificable sin abrirlo?
- ¿Qué pasa si la restauración se interrumpe por la mitad?
- ¿Conviene detener el servicio para restaurar? ¿Y para hacer el backup?
- ¿Qué diferencia hay entre un timer de systemd y una entrada de cron?
- ¿Qué ocurre con un timer si la máquina estaba apagada a la hora programada?
- ¿Cuántas copias conviene conservar y por qué? ¿Quién paga el costo de equivocarse?
- Un backup que nunca se restauró, ¿es un backup?

---

## Etapa 06 — Health check y diagnóstico

Hasta acá el sistema se protege y se recupera. Falta poder responder dos preguntas distintas: *"¿está todo bien?"* y, cuando la respuesta es que no, *"¿qué pasó?"*. Cada una necesita una herramienta propia.

### 🩺 ¿Está todo bien?

```
health-check.sh
```

Deberá verificar, como mínimo:

- **Estado de `nexusd`:** No sólo si hay un proceso vivo, sino si systemd considera que la unidad está activa y funcionando.
- **Estado de Nginx:** Si Nginx está caído, la API es inalcanzable aunque la aplicación esté perfecta. Son dos servicios distintos y pueden fallar por separado.
- **Conectividad HTTPS:** Una petición real por el mismo camino que usa el operador. Es la única comprobación que recorre toda la cadena de punta a punta.
- **Acceso a SQLite:** Que el archivo de base esté donde dice la configuración, exista y se pueda leer.
- **Espacio disponible en disco:** Un disco lleno rompe los backups, la rotación de logs y las escrituras de la base, casi siempre en ese orden y sin aviso.
- **Estado del último backup:** Cuándo se hizo y si terminó bien. Un backup de hace dos semanas es tan preocupante como uno que falló.

Este script lo va a ejecutar otro script —el de despliegue— y va a decidir en base a su resultado. Por eso su código de salida importa tanto como su salida en pantalla: tiene que distinguir un sistema sano de uno degradado y de uno caído.

### 🔍 ¿Qué pasó?

```
collect-diagnostics.sh
```

Cuando algo falla, el estado del sistema cambia rápido: los procesos se reinician, los logs se rotan y las conexiones se cierran. Este script captura una foto del momento, para poder analizarla después con calma. Deberá incluir:

- **Estado de servicios:** Qué unidades están activas, cuáles fallaron y desde cuándo.
- **Procesos relevantes:** Los procesos del sector corriendo en ese momento, con su consumo.
- **Puertos en escucha:** Qué está escuchando, en qué interfaz y qué proceso lo abrió. Sirve para detectar un servicio expuesto donde no debería.
- **Tabla de vecinos:** El estado de la red local en ese instante, para distinguir un problema de la aplicación de uno de conectividad.
- **Reglas de firewall:** Las reglas efectivamente aplicadas, que no siempre son las que alguien cree haber configurado.
- **Estado de SELinux:** El modo actual y las denegaciones recientes. Muchas fallas raras se explican acá.
- **Uso de disco:** Por sistema de archivos, no sólo el total.
- **Últimos logs:** De la aplicación y de los servicios relacionados, acotados a una ventana de tiempo razonable.
- **Resultado del health check:** La foto del estado general en el momento de la recolección, para no tener que deducirlo del resto.

El resultado tiene que ser un paquete identificable por fecha, que se pueda abrir sin herramientas especiales. Y tiene que ser compartible: piensen qué información del sistema **no** debería terminar dentro de un archivo que se le pasa a otra persona.

Valen las reglas de Bash de todo el proyecto: validar argumentos, citar correctamente las variables, usar códigos de salida significativos, limpiar archivos temporales y superar `shellcheck`.

### ✅ Se considera cumplido cuando

- Con el sistema sano, el health check termina con código 0.
- Al detener un servicio o llenar el disco, el resultado cambia y el código de salida lo refleja.
- El paquete de diagnóstico se genera con un solo comando y queda identificado por fecha.
- No contiene claves, certificados privados ni credenciales.

### 🔎 Preguntas de investigación

- ¿Qué diferencia hay entre "el proceso está corriendo" y "el servicio está sano"?
- ¿Qué debería devolver el health check si la aplicación responde pero el disco está casi lleno?
- ¿Cuántos estados distintos necesita informar y cómo se representan en un código de salida?
- ¿Qué información no debería incluirse nunca en un paquete de diagnóstico?
- ¿Para qué sirve recolectar el estado del sistema en el momento de la falla en lugar de después?

---

## Etapa 07 — El cliente del operador

El cliente Bash del capítulo anterior sirvió como andamio para probar la API mientras se construía. El operador del sector necesita otra cosa: una herramienta propia, compilada, que forme parte del sistema. Deberán implementarla en C, utilizando libcurl:

```
nexusctl
```

Comandos mínimos:

- `nexusctl health`: Consulta el estado del sector. Es el primer comando que ejecuta un operador al sentarse en la terminal.
- `nexusctl units list`: Lista las unidades registradas.
- `nexusctl incidents list`: Lista los incidentes, para ver qué hay abierto.
- `nexusctl incidents create`: Da de alta un incidente nuevo, con sus datos obligatorios.
- `nexusctl incidents close`: Cambia el estado de un incidente existente a cerrado.

El cliente deberá ejecutarse desde `field-terminal` contra la API publicada por HTTPS, validando el certificado del laboratorio igual que cualquier otro cliente. La dirección del servidor no debe estar escrita en el código: aplican las mismas reglas de configuración externa que para la aplicación.

Deberá distinguir claramente los casos de error —la API responde con un error, la API no responde, el certificado no valida— y reflejarlos en su código de salida, para que pueda usarse dentro de un script.

> **Importante:**  
> **No se implementarán sockets directamente.** Ese trabajo corresponde a Sistemas Operativos II; acá el objetivo es usar correctamente una biblioteca que ya resuelve el transporte.

### ✅ Se considera cumplido cuando

- `nexusctl health` funciona desde Rocky Linux contra la API publicada por HTTPS, sin desactivar la validación del certificado.
- Se puede crear un incidente y cerrarlo desde la línea de comandos.
- Con la API caída, el programa informa el problema con claridad y termina con un código distinto de cero.
- El binario se compila con el mismo build del proyecto.

### 🔎 Preguntas de investigación

- ¿Qué le aporta libcurl al programa que tendrían que escribir a mano si no existiera?
- ¿Cómo sabe libcurl en qué certificados confiar?
- ¿Cómo se recibe el cuerpo de una respuesta en C si la biblioteca entrega los datos por partes?
- ¿Qué debería devolver el programa si la API responde con un error? ¿Y si no responde nada?
- ¿Dónde debería configurarse la dirección del servidor: en el código, en un argumento o en un archivo?

---

## Etapa 08 — Despliegue automatizado

A esta altura el sector tiene binarios, archivos de configuración, unidades de systemd, un timer y media docena de scripts. Instalarlo a mano es largo y propenso a errores, y sobre todo: no es reproducible. Si sólo ustedes saben el orden de los pasos, el sistema no está terminado.

Todo eso tiene que poder instalarse con un solo comando:

```
deploy.sh
```

El script deberá ejecutar, en este orden:

1. **Validar dependencias:** Comprobar que estén las bibliotecas, herramientas y permisos necesarios. Si falta algo, conviene enterarse ahora y no después de haber desinstalado la versión que funcionaba.
2. **Configurar el build:** Preparar la compilación con las opciones correctas para una instalación real.
3. **Compilar:** Generar los binarios desde el código del repositorio, no desde lo que haya quedado en la máquina.
4. **Ejecutar pruebas:** Si fallan acá, el script tiene que detenerse sin haber tocado el sistema instalado.
5. **Instalar binarios:** Copiar los ejecutables a su ubicación definitiva, con el dueño y los permisos que corresponden.
6. **Instalar archivos de configuración:** Con cuidado: una configuración existente puede tener ajustes propios de esa máquina que no conviene pisar sin aviso.
7. **Instalar unidades de systemd:** Las del servicio, el backup y su temporizador.
8. **Recargar systemd:** Para que tome las unidades nuevas o modificadas. Sin este paso, systemd sigue trabajando con la versión anterior.
9. **Reiniciar los servicios:** Para que la nueva versión quede efectivamente corriendo.
10. **Ejecutar un health check:** Acá se usa el script de la etapa anterior. Es el que decide si el despliegue salió bien o no.
11. **Rollback si la validación falla:** Volver al estado anterior e informarlo. Para que esto sea posible hay que haber guardado algo antes: decidir qué y en qué momento es el corazón de esta etapa.

Fíjense dónde están las pruebas: en el paso 4, **antes** de instalar nada. Si fallan, no se toca el sistema. Y fíjense dónde está el health check: en el paso 10, después de que todo quedó instalado y reiniciado, para comprobar que el resultado realmente funciona.

El paso 11 es el que importa. Un script que instala es fácil. Un script que se da cuenta de que la instalación quedó rota y vuelve al estado anterior es una herramienta de operación. Para poder volver atrás hay que haber guardado algo antes: decidir qué, y cuándo, es la parte interesante de esta etapa.

### ✅ Se considera cumplido cuando

- Ejecutar el script dos veces seguidas deja el sistema igual de funcional que ejecutarlo una vez.
- Si las pruebas fallan, el sistema instalado no se modifica.
- Si el health check final falla, el script vuelve a la versión anterior y lo informa.
- Una persona ajena al equipo puede instalar el sector siguiendo la documentación.

### 🔎 Preguntas de investigación

- ¿Qué habría que guardar antes de instalar para poder volver atrás?
- ¿Qué significa que un despliegue sea idempotente? ¿Qué pasa si se ejecuta dos veces seguidas?
- ¿Por qué hay que recargar systemd después de instalar una unidad?
- ¿Qué parte del estado del sistema no puede revertir un rollback?
- ¿Qué debería hacer el script si lo ejecutan sin privilegios suficientes?

---

## 💥 Escenarios de falla obligatorios

El sistema no se evalúa funcionando: se evalúa fallando. Deberán poder provocar los tres escenarios siguientes durante la demostración y explicar, en cada caso, qué componente del sistema produjo la respuesta.

### 🔴 Falla 1 · Proceso terminado

Se ejecuta `kill -9` sobre `nexusd`. Esa señal no se puede manejar: el proceso muere sin ejecutar ningún cierre ordenado, igual que si se cortara la energía.

Deberán demostrar la recuperación automática, mostrar dónde quedó registrada y explicar quién la produjo.

### 🟠 Falla 2 · Base de datos no disponible

La aplicación deberá detectar el problema, registrar el error, no perder el control del proceso y retornar un código HTTP apropiado.

Acá se evalúan dos cosas a la vez: que la aplicación no se caiga, y que el cliente reciba una respuesta que describa lo que pasó en lugar de un silencio o un error genérico.

### 🟣 Falla 3 · Pérdida de información

Se elimina o reemplaza deliberadamente la base del laboratorio. El sistema deberá recuperarse desde un backup verificado, siguiendo el procedimiento documentado.

No vale improvisar durante la demostración: se ejecuta lo que está escrito.

---

## 🧪 Prueba integral

La evaluación final seguirá un escenario común, en tiempo real y con ambas máquinas encendidas. Recorre todo el proyecto, desde las VMs del primer capítulo hasta el último backup, y deberá realizarse utilizando únicamente los procedimientos documentados por el equipo.

1. **El operador inicia sesión en Rocky Linux:** Con un usuario sin privilegios administrativos, el que usaría un operador real.
2. **Verifica el estado del sector con `nexusctl`:** Comprueba de una sola vez que el cliente en C funciona, que la API responde y que el certificado valida.
3. **Registra una nueva unidad:** Una escritura simple que confirma que la cadena completa llega hasta la base.
4. **Crea un incidente crítico:** La severidad importa: es la que dispara la notificación.
5. **Carga una evidencia por SFTP:** Con el usuario restringido, desde la terminal remota.
6. **Asocia la evidencia al incidente:** Acá se verifica el checksum y se guardan los metadatos.
7. **Comprueba la notificación interna:** El incidente crítico del paso 4 tiene que haber dejado un mensaje en el buzón operativo.
8. **Consulta los eventos de auditoría:** Todo lo hecho hasta acá tiene que estar registrado y ser reconstruible leyendo la auditoría.
9. **Se fuerza la caída de `nexusd`:** Sin aviso y sin cierre ordenado.
10. **systemd recupera el servicio:** Sin que nadie intervenga. Deberán poder mostrar dónde quedó registrada la recuperación.
11. **Se realiza un backup:** Con la información de los pasos anteriores ya dentro del sistema.
12. **Se elimina la base de pruebas:** La pérdida es real: a partir de acá lo único que queda es la copia.
13. **Se restaura la información:** Siguiendo el procedimiento documentado, no improvisando.
14. **Se verifica nuevamente la API:** La unidad, el incidente y la evidencia de los primeros pasos tienen que seguir estando.

> **Evaluación en vivo:**  
> Durante la demostración podrá pedirse una explicación de cualquier paso. No se evalúa únicamente que el escenario funcione, sino que puedan decir qué componente del sistema operativo lo hace posible.

---

## ✅ Criterios de aceptación

El capítulo se considerará técnicamente completo cuando se cumplan simultáneamente las siguientes condiciones:

- **Publicación:** La API es accesible únicamente a través de Nginx, TLS valida correctamente y el puerto interno no está expuesto.
- **Aislamiento:** El firewall permite sólo lo necesario y SELinux permanece en modo enforcing.
- **Evidencias:** SFTP está restringido, las evidencias se verifican por checksum y cada acción queda trazada en auditoría.
- **Continuidad:** Los servicios se recuperan ante fallos, los límites de recursos están aplicados y los logs rotan.
- **Recuperación:** Los backups son verificables y la restauración funciona sobre una pérdida real de información.
- **Despliegue:** El sistema se instala automáticamente y la prueba integral es reproducible.
- **Operación remota:** `nexusctl` opera desde Rocky Linux contra la API publicada.

---

## ⚖️ Rúbrica de evaluación

| Dimensión | Peso |
|---|:---:|
| Nginx, TLS y aislamiento | **20%** |
| SELinux, firewall y permisos | **10%** |
| SFTP, evidencias y auditoría | **10%** |
| Backups y restauración | **15%** |
| Resiliencia y límites de systemd | **15%** |
| Automatización Bash y diagnóstico | **10%** |
| Cliente en C | **10%** |
| Prueba integral y documentación | **10%** |

---

## 🧭 Documento final: hacia Sistemas Operativos II

NEXUS-9 termina la materia como un monolito modular: una sola aplicación, en una sola máquina, con módulos bien separados por dentro. Esa separación no fue casual — fue la condición para que el sistema pueda, más adelante, repartirse entre varios nodos del distrito.

El entregable de cierre es un documento que identifique en qué se convertiría cada módulo si eso ocurriera:

| Módulo Actual | Servicio Futuro |
|---|---|
| `registry` | Registry Service |
| `incidents` | Incident Service |
| `evidence` | Evidence Service |
| `notifications` | Notification Service |
| `audit` | Audit Service |
| `Nginx` | API Gateway |

Para cada servicio, el documento deberá explicar:

- **Su responsabilidad:** Qué hace y, sobre todo, qué no le corresponde hacer. Un servicio sin un límite claro termina absorbiendo a los demás.
- **Los datos que administra:** Qué información sería suya en exclusiva. Hoy todo vive en la misma base: la pregunta es qué tablas se irían con cada servicio.
- **La API que expone:** Qué operaciones ofrecería a los demás, que no es lo mismo que las funciones que tiene hoy por dentro.
- **De qué otros servicios depende:** Qué necesita pedirle a otro para poder responder. Cada dependencia es una llamada de red que puede fallar.
- **Qué problemas aparecerían al distribuirlo:** Lo que hoy es una llamada a función pasa a ser una petición que puede demorar, fallar a medias o repetirse. ¿Qué se rompe cuando eso ocurre?
- **Qué seguiría siendo infraestructura:** No todo se convierte en un servicio. Algunas piezas siguen siendo soporte para los demás, y conviene identificarlas.

La parte más valiosa del documento es la quinta: **qué deja de funcionar cuando dos módulos que hoy comparten memoria y base de datos pasan a hablarse por la red.**

> **Aclaración importante:**  
> **No se implementarán los microservicios en esta materia.** El entregable es el análisis, no el código. En Sistemas Operativos II se incorporarán sockets, comunicación entre nodos, concurrencia distribuida y fallos parciales.

---

## ⚡ Estado esperado al finalizar

La API sólo se alcanza por HTTPS. El puerto interno no existe para el resto de la red. Las evidencias llegan verificadas y quedan trazadas. El servicio se levanta solo cuando cae, la información se puede recuperar y todo el sector se instala con un comando. El Distrito 9 ya no depende de nadie afuera.

```
          field-terminal
         nexusctl · sftp
                |
             | HTTPS
                ▼
           Nginx · TLS
                |
                ▼
         nexusd · SQLite
                |
                ▼
    backups · timers · journald

  NEXUS-9 // SECTOR OPERATIVO
```

---

## 📚 Referencias sugeridas

Estas referencias sirven como punto de partida. No contienen una "receta del TP". La intención es que utilicen documentación técnica para investigar, contrastar y justificar sus decisiones.

- **nginx — Documentación:** Guía de referencia general: bloques de servidor, TLS y redirecciones.
- **nginx — ngx_http_proxy_module:** Directivas del reverse proxy: destino, cabeceras, tiempos de espera y límites.
- **Ubuntu — ufw(8):** Reglas, políticas por defecto y estado del firewall en Ubuntu Server.
- **firewalld — Documentación:** Zonas, servicios, puertos y reglas persistentes en Rocky Linux.
- **Rocky Linux — Learning SELinux:** Modos, contextos, booleanos y análisis de denegaciones.
- **OpenSSH — sftp-server(8):** Subsistema SFTP y opciones para restringir a un usuario a un directorio.
- **OpenSSH — sshd_config(5):** Referencia de `Match`, `ChrootDirectory` y `ForceCommand`.
- **systemd — systemd.resource-control(5):** Límites de memoria, CPU y tareas aplicables a una unidad.
- **systemd — systemd.timer(5):** Temporizadores, calendarios y comportamiento ante arranques perdidos.
- **Linux — logrotate(8):** Rotación, compresión, retención y señales a los procesos que escriben.
- **SQLite — Backup:** Cómo obtener una copia consistente de una base que está en uso.
- **libcurl — Tutorial:** Interfaz easy, recepción de datos por callback, verificación TLS y manejo de errores.
- **Postfix — Basic Configuration:** Parámetros mínimos para entrega local dentro de la máquina.


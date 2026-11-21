Kevin: capturas del ensayo de instalacion de NEXUS-9 (20/11/2026)

Resumen: se siguio docs/installation.md en dos VMs nuevas (VirtualBox).
- sector-core: Ubuntu 26.04.1 LTS x86_64, IP 192.168.56.101
- field-terminal: Rocky Linux 10.2 x86_64, IP 192.168.56.102
- Commit en las dos: 44048725481ee120888afb1904fa8b7704843807 (rama TP3)
Resultado: deploy confirmado (codigo 0), health 0, TLS valido sin -k,
firewall como se espera, SELinux Enforcing, sin --insecure ni setenforce 0.

CAPTURAS (que poner en cada bloque del registro)
01, 02  Estado y commit de cada VM (SO, version, arquitectura, commit).
03      Primer backup exitoso (A6).
04      openssl verify OK, huella de la CA y health 0 (A6).
05      Servicios activos, puertos (8080 solo en 127.0.0.1) y ufw (A7).
06      nexusctl y HTTPS desde Rocky (B3/B4).
07, 08  Carga SFTP (codigo 0) y mismo SHA-256 en sector-core (B6).
09      Rechazo de shell: "This service allows sftp connections only" (B6).
10      Como operador: unidad creada y evidencia con su checksum (B7/B8).
11      Como operador: health 0 y puerto 8080 bloqueado, codigo 28 (parte C).

ACLARACIONES QUE HAY QUE ESCRIBIR EN EL INFORME
1. Esto NO es la validacion externa de #86. Lo hicimos Facundo y Claude
   (asistente de IA, que ejecuto los comandos por SSH). Es un ensayo de
   los integrantes; la tabla de "persona externa" debe quedar pendiente.
2. No hay estado inicial limpio documentado: no se capturo antes de empezar.
3. Falta la captura de la salida del deploy (despliegue confirmado,
   Primera instalacion: 0). El texto esta en ~/deploy-first.log de sector-core.
4. Diferencias respecto de la guia:
   - IP de sector-core 192.168.56.101 en vez de 192.168.56.10 (hosts, SAN
     del certificado y NEXUS_SERVER_IP=192.168.56.101).
   - Repo clonado desde un git bundle en vez de GitHub (A3/B2), por lo que
     no se probo el acceso al repositorio privado.
   - Cuenta "operador" creada sin contrasena y usada con "sudo -iu operador"
     en vez de "sudo passwd operador" + "su - operador".
   - SSH desde el host con clave temporal y sudo sin contrasena temporal
     (solo para el ensayo).
   - La carga SFTP de 07/08 y la verificacion de 8080 se hicieron con
     comandos equivalentes a los de la guia, no copiados literalmente.
   - La lista de operadores de la API estaba vacia: se creo
     "Operador de ensayo" por POST /api/v1/operators para poder seguir B8.
5. Hallazgos para corregir en la guia o revisar:
   a) B6 dice que el archivo debe quedar con modo 640, pero el put manual
      dejo 600 (captura 08), porque sftp conserva el modo del archivo local
      (mktemp crea 600). Con upload-evidence.sh (B8) si queda 640 y el
      usuario nexus puede leerlo. Corregir el texto de B6.
   b) La alerta del incidente critico: nexusd registro
      "entrega=OK" para operadores@nexus9.local, pero NO se encontro el
      correo en /var/mail ni en la cola de Postfix (nexus9.local no esta en
      mydestination). La entrega NO esta verificada. Revisar.
   c) La guia usa "su - operador" y getenforce/nexusctl con PATH normal; con
      "sudo -iu" el PATH de Rocky no incluye /usr/local/bin (solo afecta
      al atajo usado, no a la instalacion).
   d) El acceso a 8080 desde Rocky dio timeout (28), valido segun la guia.
6. Los IDs creados: unidad 1 (ENSAYO-20261121-003401), operador API 1,
   incidente 1, evidencia 1 (evidencia-ensayo-FWdJRI.bin, SHA-256
   69f2bc8e39813dd9b53e2cdbb17d4b9fa11d3f8750eee28cf315d8c38c6bf8ba).
7. Limpieza pendiente en las VMs: borrar /etc/sudoers.d/nexus-install y la
   clave "nexus9-install" de ~/.ssh/authorized_keys en ambas VMs.

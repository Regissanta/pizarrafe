# Pizarra Liga

Aplicacion Flutter para Android para registrar partidos 5 contra 5 y consultar en vivo los resultados y estadisticas de la liga. El nombre visible es **PizarraFe**.

## Funciones

- Marcador horizontal para partidos por tiempo o por objetivo de puntos.
- Estadisticas en vivo por jugador: puntos, rebotes, asistencias, triples (contados al anotar desde el boton de +3), robos de balon (ROB), balones perdidos (TO), tapas (BLK) y faltas personales (FP); los triples ya no tienen un contador manual en la fila de estadisticas.
- Botones rapidos para anotar AST, REB, ROB, TO, BLK y FP por equipo, con seleccion del jugador; los controles individuales siguen disponibles para corregir estadisticas.
- Sustituciones durante el partido: el marcador se conserva, cada jugador mantiene sus propias estadisticas y el resultado de ganado/perdido se asigna a quienes terminan jugando.
- Aviso de faltas colectivas desde el limite configurado por liga (8 por defecto), incluyendo la falta que alcanza el limite y cada falta personal posterior.
- Filtros de estadisticas por dia, semana, mes y siempre; ranking de mejor jugador por partido o periodo con el indice PTS + REB + AST + ROB + BLK - TO.
- Opcion para finalizar y guardar un partido o salir descartandolo sin guardar el resultado ni las estadisticas.
- Plantel, historial, rankings completos, comparacion cara a cara y resultados por companero.
- Administradores pueden editar el nombre de un jugador; el ID y las estadisticas historicas se conservan.
- Finanzas mensuales: cuota por jugador configurable para cada liga (RD$300 inicial en Liga La Fe y ligas nuevas), con abonos parciales y método de pago en efectivo o depósito; los selectores muestran solo el mes actual y el siguiente, para registrar pagos por adelantado sin cargar la lista. Incluye aportes comprometidos configurables por nombre (opcionales por liga), ingresos de VISITAS, gastos generales y resumen de pagos a dueños de cancha.
- Envío por WhatsApp del estado de cuota de cada miembro y de un resumen mensual para compartir con cualquier contacto o grupo desde el selector de chats de WhatsApp.
- Corrección de anotación: al sumar o restar un punto se elige a qué jugador atribuirlo; permite corregir un triple como canasta de dos.
- Eliminacion de partidos finalizados solo para administradores y propietario; al borrarlos se excluyen tambien sus estadisticas de los totales y comparaciones.
- El historial muestra un resumen compacto de cada partido finalizado; el desglose de jugadores y estadisticas se puede expandir individualmente.
- Icono propio de pizarra y balon para el APK y la aplicacion web.
- Firebase Authentication para cuentas con nombre de usuario y contrasena.
- Soporte para multiples ligas: cada una tiene su propio plantel, partidos, estadisticas y finanzas.
- Invitaciones de un solo uso para entrar a una liga; solo `rreyes` puede crear ligas e invitar administradores.
- Firestore para sincronizar los datos por liga entre dispositivos.
- Roles independientes por liga: propietario global (`rreyes`), administrador y lector.

## Vincular el proyecto Firebase `pizarraliga`

La configuracion de Firebase es especifica de cada proyecto y no se incluye en el repositorio. Antes de ejecutar la app:

1. En Firebase Console, agrega una aplicacion Android al proyecto `pizarraliga` con el ID de paquete `pizarra.fe`.
2. Descarga el archivo `google-services.json` de esa aplicacion y reemplaza `android/app/google-services.json`.
3. En Authentication, habilita el proveedor **Email/Password**.
4. Crea una base de datos de Firestore en modo produccion y publica las reglas de `firestore.rules`.
5. Agrega una aplicacion web al proyecto y habilita Firebase Hosting.
6. Agrega el dominio de Hosting `pizarraliga.web.app` a los dominios autorizados de Authentication.

La aplicacion convierte internamente cada nombre de usuario a una direccion de autenticacion con el dominio del proyecto activo (por ejemplo, `usuario@pizarraliga.firebaseapp.com`); no se solicita ni se envia correo electronico. Las cuentas de Authentication del proyecto anterior no se copian: cada usuario debe registrarse de nuevo. Los datos de prueba de `pizarrafe` permanecen en ese proyecto; la nueva instalacion comienza con la base de datos de `pizarraliga`.

### Propietario global

1. Antes de abrir el registro publico, crea la cuenta inicial directamente en Firebase Console > Authentication > Add user con el correo `rreyes@pizarraliga.firebaseapp.com` y establece ahi la contrasena privada.
2. Copia el UID asignado a esa cuenta.
3. En Firestore, crea `users/{UID}` con los campos `uid` (el UID como texto), `username` (`rreyes`) y `role` (`owner`).
4. Inicia sesion en la app con el usuario `rreyes`. Su perfil debe conservar `role: owner`; esta cuenta puede acceder a todas las ligas.

### Crear ligas, asignar administradores y migrar las cuentas actuales

1. En Firebase Authentication del proyecto `pizarraliga`, crea el usuario inicial con correo `rreyes@pizarraliga.firebaseapp.com` y una contraseña nueva.
2. Copia el UID y, en Firestore, crea `users/{UID}` con `uid` (el UID como texto), `username` (`rreyes`) y `role` (`owner`). La consola de Firebase permite crear este documento con privilegios administrativos.
3. Compila e instala la app del proyecto nuevo e inicia sesión como `rreyes`. La app prepara una liga vacía **Liga La Fe** con ID `main`.
4. Invita a los administradores y miembros desde **Cuenta**; deben crear cuentas nuevas en `pizarraliga` y registrarse con sus códigos de invitación.
5. Para crear ligas adicionales, usa **Crear liga e invitar administrador**. Cada administrador puede invitar miembros a su liga y cambiar de liga desde **Cuenta > Mis ligas**.

La migracion inicia con una base de datos nueva: los registros experimentales de `pizarrafe` no se copian. Las cuentas antiguas tampoco se transfieren; todos los usuarios, incluido `rreyes`, se crean de nuevo. El proyecto `pizarrafe` y sus datos no se modifican. No compartas codigos de invitacion publicamente.

Para el control de cuotas, cada jugador del plantel se considera miembro sujeto al monto mensual definido para su liga. Un administrador puede cambiarlo en **Finanzas > Configuración de finanzas**; el cambio no altera movimientos ya registrados. La cuota inicial es RD$300. En esa misma configuración puedes escribir el nombre de quien aporta mensualmente o dejar **Aportante fijo (opcional)** en blanco. El compromiso es de RD$2,000 y se controla separado de las cuotas. El límite de faltas colectivas también se configura por liga (8 por defecto); publica las reglas actualizadas de `firestore.rules` para poder cambiarlo. Los pagos de jugadores visitantes se registran con **Registrar pago de VISITAS** y aparecen como ingresos bajo **VISITAS**; no tienen monto mínimo ni máximo configurado. Para registrar una cuota adelantada, abre **Registrar cuota**, selecciona el miembro y el mes futuro que está pagando; el sistema guarda el abono en ese mes y calcula allí el saldo pendiente, aunque el mes actual ya esté pagado.

## Ejecutar y compilar

```sh
flutter pub get
flutter run
flutter build apk
```

Para compartir el APK con datos en la nube, primero completa los pasos de vinculacion de Firebase y vuelve a compilar. Nunca guardes contrasenas de usuarios en el codigo fuente. La app requiere Android 7.0 (API 24) o posterior por el SDK actual de Firebase Authentication.

## Compilar la version web para iPhone, iPad y navegadores

1. En Firebase Console > Configuracion del proyecto > Tus aplicaciones, agrega una aplicacion web al proyecto `pizarraliga`.
2. Copia el ID de la app web (empieza con `1:` y termina en `:web:...`) para el script de despliegue. El script obtiene la configuracion web de Firebase CLI.
3. En Authentication > Configuracion, agrega a dominios autorizados el dominio donde publicarás la app (por ejemplo, el dominio de Firebase Hosting).
4. En PowerShell, desde la raiz del proyecto, ejecuta el script para descargar la configuracion de la app web registrada, compilar y publicar. Requiere Flutter y Firebase CLI instalados y haber iniciado sesion en Firebase:

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\deploy_web.ps1 -WebAppId "ID_DE_LA_APP_WEB"
```

El script obtiene los valores con `firebase apps:sdkconfig`, los pasa como `--dart-define` a Flutter y publica `build/web` y `firestore.rules` en el proyecto `pizarraliga`. Necesita Firebase CLI autenticado con una cuenta que tenga acceso al proyecto. No guardes contrasenas en el script ni en el codigo fuente.

Si prefieres hacer el despliegue manual, instala Firebase CLI e inicia sesion:

```powershell
npm.cmd install --global firebase-tools
& "$env:APPDATA\npm\firebase.cmd" login
```

El inicio de sesion abre Google en el navegador; autoriza Firebase CLI con la cuenta personal que tiene acceso al proyecto `pizarraliga`. `firebase.json` y `.firebaserc` estan configurados para publicar en ese proyecto. Al terminar, la CLI mostrara el enlace de Hosting, normalmente `https://pizarraliga.web.app`.

Los usuarios de iPhone/iPad podrán abrir el enlace en Safari y agregarlo a la pantalla de inicio. El registro y los datos compartidos siguen usando Firebase. La configuracion web se incluye en el JavaScript compilado y no debe tratarse como una contraseña; protege los datos con las reglas de Firestore y limita la clave de API desde Google Cloud cuando sea posible.

La compilacion web es independiente del APK: no modifica ni reemplaza `build/app/outputs/flutter-apk/app-release.apk`. El APK usa el `google-services.json` del proyecto `pizarraliga` y se sigue compilando con `flutter build apk`.


PARA ACTUALIZAR LA VERSION WEB
https://pizarraliga.firebaseapp.com/
- PS C:\Users\Sr Cardenal\PIZARRA> firebase.cmd login
- PS C:\Users\Sr Cardenal\PIZARRA> & "$env:APPDATA\npm\firebase.cmd" login
- PS C:\Users\Sr Cardenal\PIZARRA> & "$env:APPDATA\npm\firebase.cmd" apps:list WEB --project pizarraliga
- PS C:\Users\Sr Cardenal\PIZARRA> powershell -ExecutionPolicy Bypass -File ".\tool\deploy_web.ps1" -WebAppId "1:801761334897:web:2138d7f176bb39a5466dd0"   (NOTA ESE CODIGO ES EL QUE DA EL TERCER COMANDO)


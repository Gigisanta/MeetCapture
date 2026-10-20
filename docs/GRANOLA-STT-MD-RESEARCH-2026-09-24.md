# Ideas de Granola y stt-md para MeetCapture (2026-09-24)

## Fuentes y alcance

- [Granola 101](https://docs.granola.ai/help-center/getting-started/granola-101): producto comercial, con notas antes y durante reuniones, plantillas y chat entre reuniones. GitHub ofrece [integraciones de terceros](https://github.com/magarcia/granola-cli), no el código fuente de la app.
- [Open Granola](https://github.com/anshuman-pandey/open-granola): alternativa abierta que propone informes previos, seguimiento de compromisos y búsqueda semántica local.
- [stt-md](https://github.com/dreamxist/stt-md): app macOS abierta que genera Markdown/Obsidian y usa un vocabulario cerrado de etiquetas para evitar categorías inventadas por el LLM.

Tomamos patrones de producto y escribimos código propio sobre la arquitectura Swift + dispatcher existente. No importamos código ni recursos de estos proyectos.

## Aplicado en esta iteración

| Idea | Resultado en MeetCapture |
| --- | --- |
| Notas de la persona durante la reunión (Granola) | Editor en el popover mientras graba. Guarda un sidecar privado por reunión; el dispatcher lo usa como contexto y lo conserva en los artefactos. |
| Nota portable (stt-md) | `.summary.md` con frontmatter, resumen, decisiones, tareas marcables, asistentes y transcripción; se abre desde el historial. |
| Vocabulario controlado (stt-md) | Carpeta opcional de Markdown: se leen sólo nombres de etiquetas, se pasan como lista permitida y se filtra la respuesta. La lectura está acotada. |
| Resumen con tareas concretas (ambos) | El prompt exige JSON y pide responsables y fechas sólo si aparecen en las fuentes. |

## Próximas mejoras de producto

1. **Informe previo con contexto verificable.** Reunir últimas notas y pendientes de los asistentes de una reunión del calendario. Cada afirmación debe apuntar a la reunión origen; sin asistentes o historial suficiente, mostrar ausencia de contexto.
2. **Seguimiento de compromisos.** Pasar de strings de `action_items` a tareas estructuradas con responsable, fecha, estado y evidencia, sin crear responsables inferidos. Permitir marcar tareas desde la app y mostrar las pendientes antes de la próxima reunión.
3. **Consulta entre reuniones.** Usar la búsqueda local existente como recuperador y responder con enlaces a segmentos de transcripción. Empezar con FTS5 y sólo agregar embeddings si la evaluación muestra ganancia real.
4. **Plantillas por tipo de reunión.** Entrevista, ventas, proyecto, uno a uno; conservar la estructura estable de decisiones y tareas para las integraciones.
5. **Salida a vault configurable.** Exportación optativa y segura a Obsidian/Markdown con nombres estables y manejo explícito de colisiones; la nota en `~/meetings` sigue siendo la fuente canónica.

## Límites actuales

- El editor toma notas sólo desde que empieza la grabación; todavía no crea notas anticipadas desde el calendario.
- Las etiquetas se leen de hasta 300 archivos regulares Markdown de 64 KiB, y se envían como nombres al endpoint de resumen configurado. No se transfieren los archivos del vault.
- Las tareas son texto marcable en Markdown; no hay estado sincronizado de pendientes.
- La prueba aislada del dispatcher no verifica la calidad de un modelo real ni una llamada capturada en vivo.

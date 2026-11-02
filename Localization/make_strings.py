#!/usr/bin/env python3
"""Genera es.lproj y en.lproj/Localizable.strings y avisa de los textos de Revela.swift sin traducir.

Uso:  python3 Localization/make_strings.py
Las claves son los textos en español tal como aparecen en el código.
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))

# Claves que en español se muestran distinto (para distinguir significados de una misma palabra)
ES = {
    "Tono (básico)": "Tono",
}

EN = {
    # Módulos, paneles y grupos
    "Biblioteca": "Library", "Revelar": "Develop", "Biblioteca / Revelar": "Library / Develop",
    "Biblioteca  (G)": "Library  (G)", "Revelar  (D)": "Develop  (D)",
    "Básico": "Basic", "Curva de tonos": "Tone Curve", "Mezcla de colores": "Color Mixer", "Mezcla B/N": "B&W Mixer",
    "Gradación de color": "Color Grading", "Detalle": "Detail", "Óptica": "Optics", "Geometría": "Geometry",
    "Efectos": "Effects", "Calibración": "Calibration", "Navegador": "Navigator", "Ajustes preestablecidos": "Presets",
    "Historial": "History", "Integrados": "Built-in", "Del usuario": "User presets", "Ajustes de la foto": "Photo adjustments",
    "Tono (básico)": "Tone", "Presencia": "Presence", "Enfoque": "Sharpening", "Reducción de ruido": "Noise Reduction",
    "Manual": "Manual", "Desflecar": "Defringe", "Viñeta tras recorte": "Post-Crop Vignetting", "Granulado": "Grain",
    "Región": "Region", "Primario rojo": "Red Primary", "Primario verde": "Green Primary", "Primario azul": "Blue Primary",
    "Herramientas": "Tools", "Vista": "View", "Edición": "Edit", "Archivo": "File", "Ajustes": "Settings", "Foto": "Photo",
    # Básico
    "Tratamiento": "Treatment", "Color": "Color", "Blanco y negro": "Black & White", "Perfil": "Profile",
    "Vívido": "Vivid", "Neutro": "Neutral", "Paisaje": "Landscape", "Retrato": "Portrait", "Monocromo": "Monochrome",
    "Balance": "WB", "Como se tomó": "As Shot", "Automático": "Auto", "Personalizado": "Custom",
    "Luz de día": "Daylight", "Nublado": "Cloudy", "Sombra": "Shade", "Tungsteno": "Tungsten", "Fluorescente": "Fluorescent",
    "Flash": "Flash", "Luz": "Light", "Temp.": "Temp", "Matiz": "Tint", "Auto": "Auto",
    "Exposición": "Exposure", "Contraste": "Contrast", "Iluminaciones": "Highlights", "Sombras": "Shadows",
    "Blancos": "Whites", "Negros": "Blacks", "Textura": "Texture", "Claridad": "Clarity", "Neblina": "Dehaze",
    "Intensidad": "Vibrance", "Saturación": "Saturation",
    "HDR": "HDR", "Edición HDR": "HDR editing", "Rango HDR": "HDR range",
    "Esta pantalla no muestra HDR: verás las luces recortadas, pero el HEIC exportado sí las conserva.":
        "This display can't show HDR: highlights will look clipped, but the exported HEIC keeps them.",
    "Las luces pueden superar el blanco hasta %@ pasos. Exporta en HEIC para conservar el HDR; en JPEG, TIFF o PNG se comprimen las luces.":
        "Highlights can go up to %@ stops above white. Export as HEIC to keep the HDR; JPEG, TIFF and PNG compress the highlights.",
    "Selector de balance de blancos (W): haz clic en algo neutro": "White balance selector (W): click something neutral",
    # Curva, mezcla, gradación
    "Param.": "Param.", "RGB": "RGB", "Claros": "Lights", "Oscuros": "Darks", "Restablecer canal": "Reset channel",
    "Restablecer curva": "Reset curve", "Clic para añadir un punto · arrastra fuera del gráfico para eliminarlo":
        "Click to add a point · drag it off the graph to remove it",
    "Mezcla": "Mixer", "Punto de color": "Point Color", "Tono": "Hue", "Luminancia": "Luminance", "Todo": "All",
    "Rojo": "Red", "Naranja": "Orange", "Amarillo": "Yellow", "Verde": "Green", "Aguamarina": "Aqua", "Azul": "Blue",
    "Púrpura": "Purple", "Magenta": "Magenta",
    "Elegir un color de la foto": "Pick a color from the photo", "Variación": "Variance", "Rango": "Range",
    "Visualizar rango": "Visualize range", "Rango del punto de color": "Point color range",
    "Pulsa el cuentagotas y haz clic en la foto para ajustar solo ese color (hasta 8).":
        "Click the eyedropper, then click the photo to adjust just that color (up to 8).",
    "Selecciona una muestra para ajustarla.": "Select a swatch to adjust it.",
    "Máximo 8 puntos de color por foto": "Up to 8 point colors per photo", "Nuevo punto de color": "New point color",
    "Eliminar punto de color": "Delete point color", "Haz clic en el color que quieres ajustar": "Click the color you want to adjust",
    "3 vías": "3-way", "Medios": "Mids", "Ilum.": "Highl.", "Global": "Global", "Medios tonos": "Midtones",
    "Fusión": "Blending", "Equilibrio": "Balance", "Gradación: %@": "Color grading: %@", "Luminancia %@": "Luminance %@",
    # Detalle, óptica, geometría, efectos, calibración
    "Cantidad": "Amount", "Radio": "Radius", "Máscara": "Masking", "Suavidad": "Smoothness",
    "Eliminar aberración cromática": "Remove chromatic aberration", "Usar correcciones de perfil (RAW)": "Use profile corrections (RAW)",
    "Correcciones de perfil": "Profile corrections", "Distorsión": "Distortion", "Viñeta": "Vignetting",
    "Punto medio": "Midpoint", "Vertical": "Vertical", "Horizontal": "Horizontal", "Girar": "Rotate", "Aspecto": "Aspect",
    "Escala": "Scale", "Desplaz. X": "Offset X", "Desplaz. Y": "Offset Y", "Restablecer geometría": "Reset geometry",
    "Nivelar": "Level", "Nivela la foto y corrige las verticales que convergen (edificios)":
        "Levels the photo and fixes converging verticals (buildings)",
    "Solo endereza el horizonte o las líneas rectas": "Only straightens the horizon or straight lines",
    "Analizando líneas verticales…": "Analyzing vertical lines…", "No se han encontrado líneas verticales claras":
        "No clear vertical lines found", "La geometría ya está recta": "The geometry is already straight",
    "Geometría automática": "Auto geometry",
    "Redondez": "Roundness", "Desvanecer": "Feather", "Tamaño": "Size", "Aspereza": "Roughness",
    # Recortar y enderezar
    "Recortar": "Crop", "Recortar y enderezar": "Crop & Straighten", "Recortar y enderezar (R)": "Crop & Straighten (R)",
    "Recortar  (R)": "Crop  (R)", "Ángulo": "Angle", "Restablecer recorte": "Reset crop", "Enderezar auto": "Auto straighten",
    "Enderezar automáticamente": "Straighten automatically", "Nivela el horizonte o las líneas rectas de la foto":
        "Levels the horizon or straight lines in the photo", "Buscando el horizonte…": "Looking for the horizon…",
    "No se ha encontrado un horizonte ni líneas rectas claras": "No clear horizon or straight lines found",
    "La foto ya está recta": "The photo is already straight", "Libre": "Free", "Original": "Original",
    "1 x 1": "1 x 1", "2 x 3": "2 x 3", "3 x 4": "3 x 4", "4 x 5": "4 x 5", "5 x 7": "5 x 7", "9 x 16": "9 x 16",
    "Cambiar orientación del recorte (X)": "Rotate crop orientation (X)", "Aspecto de recorte %@": "Crop aspect %@",
    "Orientación del recorte": "Crop orientation",
    # Máscaras
    "Máscaras": "Masks", "Máscaras (M)": "Masks (M)", "Máscaras  (M)": "Masks  (M)", "Crear nueva máscara": "Create new mask",
    "En esta foto": "In this photo", "Sujeto": "Subject", "Personas": "People", "Fondo": "Background", "Pincel": "Brush",
    "Degradado lineal": "Linear gradient", "Degradado radial": "Radial gradient", "Rango de color": "Color range",
    "Rango de luminancia": "Luminance range", "Lineal": "Linear", "Radial": "Radial",
    "Detecta automáticamente el sujeto principal": "Automatically detects the main subject",
    "Detecta automáticamente a todas las personas": "Automatically detects all people",
    "Selecciona todo lo que no es el sujeto principal": "Selects everything that isn't the main subject",
    "Seleccionar sujeto": "Select subject", "Seleccionar personas": "Select people", "Seleccionar fondo": "Select background",
    "Detectando sujeto…": "Detecting subject…", "Detectando personas…": "Detecting people…", "Detectando fondo…": "Detecting background…",
    "No se ha encontrado ningún sujeto": "No subject found", "No se han encontrado personas": "No people found",
    "Volver a detectar": "Detect again", "Volver a detectar: %@": "Detect again: %@", "Nueva máscara: %@": "New mask: %@",
    "Si cambias la geometría o el enderezado, vuelve a detectar.": "If you change geometry or straightening, detect again.",
    "Las máscaras aplican ajustes solo a una zona de la foto. Empieza eligiendo un tipo.":
        "Masks apply adjustments to just one area of the photo. Start by choosing a type.",
    "Crea una máscara en el panel derecho": "Create a mask in the right panel",
    "Invertir": "Invert", "Invertir máscara": "Invert mask", "Quitar inversión": "Remove inversion", "INV": "INV",
    "Superposición (O)": "Overlay (O)", "Superposición de máscara": "Mask overlay", "Duplicar": "Duplicate",
    "Duplicar máscara": "Duplicate mask", "Eliminar": "Delete", "Eliminar máscara": "Delete mask", "Editar máscara": "Edit mask",
    "Ajustes de máscara": "Mask adjustments", "Restablecer ajustes": "Reset adjustments",
    "Restablecer ajustes de máscara": "Reset mask adjustments", "Mostrar máscara": "Show mask", "Ocultar máscara": "Hide mask",
    "Activar / desactivar": "Enable / disable", "Borrar (o mantén ⌥)": "Erase (or hold ⌥)", "Borrar trazos": "Clear strokes",
    "Flujo": "Flow", "Pinta sobre la foto para añadir zona a la máscara. La rueda cambia el tamaño.": "Paint on the photo to add area to the mask. Scroll to change the size.",
    "Arrastra sobre la foto para trazar el degradado. El punto central lo mueve; los extremos ajustan la transición.":
        "Drag on the photo to draw the gradient. The center point moves it; the ends adjust the transition.",
    "Arrastra el centro para moverlo y los puntos del borde para cambiar su tamaño. Arrastra fuera para dibujar uno nuevo.":
        "Drag the center to move it and the edge points to resize it. Drag outside to draw a new one.",
    "Ajustar": "Refine", "Haz clic en la foto para elegir otro color.": "Click the photo to pick another color.",
    "Haz clic en la foto sobre el color que quieres seleccionar.": "Click the photo on the color you want to select.",
    "Desde": "From", "Hasta": "To", "Suavizado": "Smoothness",
    "Haz clic en la foto para centrar el rango en ese tono.": "Click the photo to center the range on that tone.",
    "Elegir color": "Pick color", "Elegir luminancia": "Pick luminance", "Color de máscara": "Mask color",
    "Nitidez": "Sharpness", "Ruido": "Noise",
    # Eliminar manchas
    "Eliminar manchas": "Spot removal", "Eliminar manchas  (Q)": "Spot removal  (Q)",
    "Eliminar manchas y objetos (Q)": "Remove spots and objects (Q)", "Corregir": "Heal", "Clonar": "Clone",
    "Modo corregir": "Heal mode", "Modo clonar": "Clone mode", "Nuevas correcciones": "New spots",
    "Corrección seleccionada": "Selected spot", "Opacidad": "Opacity", "Mostrar puntos (H)": "Show spots (H)",
    "Mostrar puntos de corrección": "Show spot pins", "Sin correcciones": "No spots", "%@ correcciones": "%@ spots",
    "Borrar todas": "Clear all", "Borrar correcciones": "Clear spots", "Eliminar corrección": "Delete spot",
    "Mover corrección": "Move spot", "Haz clic sobre una mancha para eliminarla": "Click a spot to remove it",
    "Haz clic sobre una mancha para eliminarla: el origen se elige solo. Arrastra el círculo discontinuo para usar otro origen. ⌫ borra la seleccionada.":
        "Click a spot to remove it: the source is picked automatically. Drag the dashed circle to use another source. ⌫ deletes the selected one.",
    # Balance de blancos y tono automático
    "Balance de blancos": "White balance", "Balance de blancos  (W)": "White balance  (W)",
    "Balance de blancos con cuentagotas (W)": "White balance eyedropper (W)",
    "Balance de blancos (cuentagotas)": "White balance (eyedropper)", "Balance de blancos automático": "Auto white balance",
    "Balance de blancos: como se tomó": "White balance: as shot", "Balance de blancos: %@": "White balance: %@",
    "Haz clic en una zona neutra (gris o blanca)": "Click a neutral area (gray or white)",
    "Tono automático": "Auto tone",
    # Ajustes preestablecidos
    "B/N alto contraste": "B&W high contrast", "B/N suave": "B&W soft", "Película cálida": "Warm film",
    "Teal & Orange": "Teal & Orange", "Mate": "Matte", "Paisaje dramático": "Dramatic landscape",
    "Retrato luminoso": "Bright portrait", "Frío nórdico": "Nordic cold",
    "Pulsa + para guardar los ajustes actuales.": "Press + to save the current settings.",
    "Guardar los ajustes actuales como preestablecido (⇧⌘N)": "Save the current settings as a preset (⇧⌘N)",
    "Nuevo ajuste preestablecido": "New preset", "Nuevo ajuste preestablecido…": "New preset…",
    "Guarda los ajustes actuales (sin recorte ni geometría).": "Saves the current settings (without crop or geometry).",
    "Guardar": "Save", "Sin nombre": "Untitled", "Mi ajuste %@": "My preset %@",
    # Edición y menús
    "Deshacer": "Undo", "Rehacer": "Redo", "Deshacer / rehacer": "Undo / redo", "Copiar ajustes": "Copy settings",
    "Pegar ajustes": "Paste settings", "Copiar / pegar ajustes": "Copy / paste settings", "Ajustes copiados": "Settings copied",
    "Ajustes anteriores": "Previous settings", "Pegar ajustes copiados": "Paste copied settings", "Restablecer": "Reset",
    "Restablecer %@": "Reset %@", "Vuelve a los valores por defecto (⇧⌘R)": "Back to defaults (⇧⌘R)",
    "Anterior": "Previous", "Aplica los ajustes de la foto anterior (⌥⌘V)": "Applies the previous photo's settings (⌥⌘V)",
    "Girar a la izquierda": "Rotate left", "Girar a la derecha": "Rotate right", "Girar a la izquierda (⌘[)": "Rotate left (⌘[)",
    "Girar a la derecha (⌘])": "Rotate right (⌘])", "Voltear horizontal": "Flip horizontal", "Perfil %@": "Profile %@",
    "Atajos de teclado": "Keyboard shortcuts", "Atajos de teclado (?)": "Keyboard shortcuts (?)", "Cerrar": "Close",
    "Mostrar u ocultar el panel izquierdo": "Show or hide the left panel", "Idioma de la interfaz": "Interface language",
    "Ocultar paneles": "Hide panels", "Ocultar paneles  (Tab)": "Hide panels  (Tab)",
    "Foto anterior  (←)": "Previous photo  (←)", "Foto siguiente  (→)": "Next photo  (→)",
    "Foto anterior / siguiente": "Previous / next photo", "Quitar del catálogo": "Remove from catalog",
    "Mostrar en Finder": "Show in Finder", "Cerrar herramienta": "Close tool", "Borrar máscara o corrección": "Delete mask or spot",
    "Marcar varias fotos": "Mark several photos", "Ajuste fino": "Fine adjust", "Doble clic": "Double-click",
    "Restablecer un deslizador": "Reset a slider", "Z / espacio": "Z / space", "⌥ + arrastrar": "⌥ + drag",
    "⇧⌘I  ·  o arrástralas a la ventana": "⇧⌘I  ·  or drag them into the window", "⌘ / ⇧ + clic": "⌘ / ⇧ + click",
    "Hecho": "Done", "Manchas": "Spots", "Orientación": "Orientation",
    "Clic sobre una mancha: corrección circular. Arrastra para pintar sobre manchas alargadas (cables, pelos, grietas). El origen se elige solo; arrastra el contorno discontinuo para cambiarlo. La rueda cambia el tamaño. ⌫ borra la seleccionada.":
        "Click a spot: circular fix. Drag to paint over long blemishes (cables, hairs, cracks). The source is picked automatically; drag the dashed outline to change it. Scroll to change the size. ⌫ deletes the selected one.",
    "Clonar (pincel)": "Clone (brush)", "Corregir (pincel)": "Heal (brush)", "Quitar": "Clear",
    "Origen fijado (⌥-clic): las siguientes correcciones lo usan alineado.": "Source set (⌥-click): the next fixes use it, aligned.",
    "Tamaño de corrección": "Spot size",
    "⌥-clic en la foto fija el origen a mano, como el pincel corrector de Photoshop.": "⌥-click on the photo to set the source by hand, like Photoshop's healing brush.",
    "⌥ + arrastrar una esquina o un borde: recorte simétrico desde el centro.": "⌥ + drag a corner or edge: symmetric crop from the center.",
    "⌥ + esquina": "⌥ + corner", "Recorte simétrico desde el centro": "Symmetric crop from the center",
    # Monitores, falso color, lupa y evaluación de color
    "Histograma": "Histogram", "Forma de onda (luminancia)": "Waveform (luminance)", "Desfile RGB": "RGB parade",
    "Vectorscopio": "Vectorscope", "Falso color": "False color", "Falso color  (F)": "False color  (F)",
    "Falso color de exposición (F)": "Exposure false color (F)", "Negro": "Black", "Muy oscuro": "Very dark",
    "Gris medio": "Middle gray", "Piel +1": "Skin +1", "Casi blanco": "Near white", "Quemado": "Clipped",
    "Lupa": "Loupe", "Lupa  (L)": "Loupe  (L)", "Lupa · rueda para ampliar": "Loupe · scroll to magnify", "Lupa bajo el cursor (L)": "Loupe under the cursor (L)",
    "Evaluación de color": "Color assessment", "Evaluación de color  (C)": "Color assessment  (C)",
    "Evaluación de color: fondo gris y marco blanco (C)": "Color assessment: gray background and white frame (C)",
    # Paneles: restablecer, ojo, modo solo
    "Doble clic para restablecer %@": "Double-click to reset %@",
    "Doble clic para restablecer · ⌥ + arrastrar para ajuste fino": "Double-click to reset · ⌥ + drag for fine adjustment",
    "Activar el panel": "Enable the panel", "Desactivar el panel para ver qué aporta": "Disable the panel to see what it adds",
    "⌥-clic: abrir solo este panel": "⌥-click: open only this panel", "Modo solo (un panel abierto)": "Solo mode (one panel open)",
    "Expandir todos": "Expand all", "Contraer todos": "Collapse all",
    "Paneles desactivados: vista previa parcial": "Panels disabled: partial preview",
    "Arrastra para cambiar el ancho · doble clic para restablecer": "Drag to change the width · double-click to reset",
    "Arrastra sobre el histograma para ajustar negros, sombras, exposición, iluminaciones o blancos":
        "Drag on the histogram to adjust blacks, shadows, exposure, highlights or whites",
    # Vista, zoom y comparación
    "Antes": "Before", "Después": "After", "Dividido": "Split", "Lado a lado": "Side by side", "Referencia": "Reference",
    "Actual": "Current", "Antes  (\\)": "Before  (\\)", "Antes / después dividido": "Before / after split",
    "Antes / después dividido  (Y)": "Before / after split  (Y)", "Antes / después lado a lado": "Before / after side by side",
    "Antes (\\) · Dividido (Y) · Referencia: clic derecho en una miniatura":
        "Before (\\) · Split (Y) · Reference: right-click a thumbnail",
    "Usar como referencia para comparar": "Use as reference for comparison", "Quitar como referencia": "Remove as reference",
    "Referencia · %@": "Reference · %@", "Elige una referencia (clic derecho en la tira)": "Choose a reference (right-click the filmstrip)",
    "Encajar": "Fit", "Encajar en la ventana": "Fit in window", "Acercar": "Zoom in", "Alejar": "Zoom out", "Zoom 1:1": "Zoom 1:1",
    "Zoom: pellizca, usa la rueda o ⌘ + desplazar · Z alterna": "Zoom: pinch, use the wheel or ⌘ + scroll · Z toggles",
    "Clic para ampliar ahí · arrastra para desplazarte": "Click to zoom there · drag to pan",
    "Aviso de recorte": "Clipping warning", "Aviso de recorte  (J)": "Clipping warning  (J)",
    "Aviso de recorte de luces y sombras (J)": "Highlight and shadow clipping warning (J)",
    "Mostrar luces quemadas en rojo (J)": "Show clipped highlights in red (J)",
    "Mostrar sombras empastadas en azul (J)": "Show clipped shadows in blue (J)",
    # Igualar exposición y selección
    "Igualar exposición": "Match exposure", "Igualar todas": "Match all", "Igualando exposición…": "Matching exposure…",
    "Iguala el brillo de las fotos marcadas al de la actual (⌥⇧⌘M)": "Matches the brightness of marked photos to the current one (⌥⇧⌘M)",
    "La exposición ya coincide": "Exposure already matches", "Exposición igualada en %@ foto": "Exposure matched on %@ photo",
    "Exposición igualada en %@ fotos": "Exposure matched on %@ photos",
    "Importa más fotos para igualar su exposición": "Import more photos to match their exposure",
    "No se ha podido medir la foto de referencia": "Couldn't measure the reference photo",
    "No hay otras fotos marcadas (⌘-clic o ⇧-clic en la tira). ¿Igualar la exposición de las otras %@ fotos a la de esta?":
        "No other photos are marked (⌘-click or ⇧-click the filmstrip). Match the exposure of the other %@ photos to this one?",
    "%@ marcadas": "%@ marked", "%@ de %@": "%@ of %@",
    # Importar y fotos no encontradas
    "Importar": "Import", "Importar fotos": "Import photos", "Importar fotos…": "Import photos…", "Importar…": "Import…",
    "Elige fotos (RAW, JPEG, HEIC, TIFF, PNG…) o carpetas": "Choose photos (RAW, JPEG, HEIC, TIFF, PNG…) or folders",
    "Empieza importando tus fotos": "Start by importing your photos",
    "RAW, JPEG, HEIC, TIFF o PNG. Tus originales nunca se modifican.": "RAW, JPEG, HEIC, TIFF or PNG. Your originals are never modified.",
    "No encontrada": "Missing", "%@ no encontradas": "%@ missing", "Localizar": "Locate", "Localizar…": "Locate…",
    "Clic derecho en la miniatura ▸ Localizar…": "Right-click the thumbnail ▸ Locate…", "No se encuentra «%@»": "Can't find “%@”",
    "Se ha movido, renombrado o el disco no está conectado. Tus ajustes se conservan.":
        "It was moved, renamed, or the drive isn't connected. Your settings are kept.",
    "¿Dónde está ahora %@?": "Where is %@ now?", "Foto localizada": "Photo located",
    "Foto localizada y %@ más en la misma carpeta": "Photo located, plus %@ more in the same folder",
    # Exportar
    "Exportar": "Export", "Exportar…": "Export…", "Exportar aquí": "Export here", "Ajustes rápidos": "Quick settings",
    "Web · JPEG 2048 px, sin ubicación": "Web · JPEG 2048 px, no location",
    "Redes sociales · JPEG 1080 px de ancho, sin metadatos": "Social media · JPEG 1080 px wide, no metadata",
    "Impresión · TIFF 16 bits, tamaño original": "Print · 16-bit TIFF, original size", "Archivo · HEIC calidad 95": "Archive · HEIC quality 95",
    "Fotos": "Photos", "Foto seleccionada": "Selected photo", "Marcadas (%@)": "Marked (%@)", "Todas (%@)": "All (%@)",
    "Destino": "Destination", "Carpeta": "Folder", "Carpeta elegida": "Chosen folder", "Junto a cada original": "Next to each original",
    "Se preguntará al exportar": "You'll be asked when exporting", "Elegir": "Choose", "Elegir…": "Choose…",
    "Subcarpeta (opcional)": "Subfolder (optional)", "Nombre de archivo": "File name", "Nombre": "Name",
    "Nombre original": "Original name", "Original + sufijo": "Original + suffix", "Nombre + número": "Name + number",
    "Sufijo (p. ej. -editada)": "Suffix (e.g. -edited)", "Nombre base (p. ej. Viaje)": "Base name (e.g. Trip)", "Ejemplo: %@": "Example: %@",
    "Formato": "Format", "Calidad": "Quality", "TIFF 16 bits": "16-bit TIFF", "Tamaño de imagen": "Image size",
    "Tamaño original": "Original size", "Lado largo": "Long edge", "Lado corto": "Short edge", "Ancho": "Width", "Alto": "Height",
    "Megapíxeles": "Megapixels", "Porcentaje": "Percent", "Valor": "Value", "No ampliar": "Don't enlarge",
    "Resolución": "Resolution", "%@ ppp": "%@ ppi", "Foto actual: %@ × %@ px": "Current photo: %@ × %@ px",
    "Metadatos": "Metadata", "Incluir": "Include", "Todos": "All", "Todos menos la ubicación": "All except location",
    "Ninguno (eliminar)": "None (remove)",
    "Cámara, objetivo, ajustes de toma, fecha, ubicación GPS y copyright.": "Camera, lens, shooting settings, date, GPS location and copyright.",
    "Se eliminan las coordenadas GPS y el lugar; se conserva el resto.": "GPS coordinates and place are removed; everything else is kept.",
    "La copia no lleva datos de cámara, fecha, ubicación ni autor.": "The copy carries no camera, date, location or author data.",
    "Cancelar": "Cancel", "Cancelar la exportación": "Cancel export", "No hay fotos que exportar": "No photos to export",
    "Exportando %@ de %@": "Exporting %@ of %@", "Exportadas %@ fotos": "Exported %@ photos",
    "Exportación cancelada: %@ fotos": "Export canceled: %@ photos", " · %@ con errores": " · %@ with errors",
    " · %@ no encontradas": " · %@ missing",
    # Varios
    " (histograma)": " (histogram)", " copia": " copy", "Mostrar": "Show",
}

# Textos que no se traducen (códigos, teclas, nombres propios, formatos)
SAME = re.compile(r"^(?:[A-Z]|[A-Z]{2,5}|[\d x/]+|IMG_0001|Revela10bc|Revela|English|Español|Do Nothing|Fill|Minimize|None|Tab|MP|G / D|"
                  r"Later|Restart now|Restart Revela10bc to switch to English\?|Reiniciar ahora|Más tarde|"
                  r"¿Reiniciar Revela10bc para cambiar a español\?|-c|/bin/sh|%.*|f/%.1f|[⌘⌥⇧↩←→\s/A-Z\[\]·Esc]+)$")


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def write(lang, table):
    d = os.path.join(HERE, f"{lang}.lproj")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        f.write(f"/* Revela — {lang}. Generado por make_strings.py: edita ese archivo, no este. */\n\n")
        for k in sorted(table):
            f.write(f'"{escape(k)}" = "{escape(table[k])}";\n')


def code_keys():
    src = open(os.path.join(HERE, "..", "Revela.swift"), encoding="utf-8").read()
    src = re.sub(r"(?m)^\s*//[^\n]*", "", src)
    keys = set()
    for raw in re.findall(r'"((?:[^"\\\n]|\\.)*)"', src):
        if "\\(" in raw or not re.search(r"[A-Za-zÁÉÍÓÚáéíóúñÑ¿]", raw):
            continue
        if raw.startswith(("CI", "input", "kCI", "public.", "com.", "NS", "panel.", "export.", "local.", "Apple")):
            continue
        if re.fullmatch(r"[a-z0-9.]+", raw) or re.fullmatch(r"[a-z][A-Za-z0-9]*", raw):
            continue
        keys.add(bytes(raw, "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8"))
    return keys


if __name__ == "__main__":
    write("es", ES)
    write("en", EN)
    missing = sorted(k for k in code_keys() if k not in EN and not SAME.match(k))
    print(f"en: {len(EN)} textos · es: {len(ES)} · sin traducir: {len(missing)}")
    for k in missing:
        print("  ·", k)

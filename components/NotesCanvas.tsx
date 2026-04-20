import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowLeft,
  ArrowRight,
  Eraser,
  GripHorizontal,
  Highlighter,
  Maximize2,
  Minimize2,
  Palette,
  PenLine,
  Plus,
  RectangleHorizontal,
  Save,
  Slash,
  Trash2,
  X,
} from 'lucide-react';

export type DrawingTool = 'pen' | 'eraser' | 'highlighter' | 'line' | 'rect';

type DrawingPoint = { x: number; y: number };
type DrawingStroke = {
  tool: DrawingTool;
  color: string;
  size: number;
  points: DrawingPoint[];
};

type DrawingDocument = {
  version: 1;
  strokes: DrawingStroke[];
};

type NotesToolset = 'quick' | 'advanced' | 'structured';
type NotesToolbarPlacement = 'bottom-center' | 'top-right';

interface NotesCanvasProps {
  initialText: string;
  initialDrawingJson?: string | null;
  documentKey?: string;
  placeholder: string;
  currentPage?: number;
  totalPages?: number;
  onPageChange?: (page: number) => void;
  onSave: (payload: { text: string; drawingJson: string; previewDataUrl: string }) => Promise<void> | void;
  onAddPage?: () => Promise<void> | void;
  onDeletePage?: () => Promise<void> | void;
  canDeletePage?: boolean;
  mode?: 'freeform' | 'grid';
  showText?: boolean;
  toolset?: NotesToolset;
  allowPagination?: boolean;
  showSaveButton?: boolean;
  onDraftChange?: (payload: { text: string; drawingJson: string; isDirty: boolean }) => void;
  embedded?: boolean;
  toolbarDockedToBorder?: boolean;
  toolbarOffsetClassName?: string;
  toolbarPlacement?: NotesToolbarPlacement;
  toolbarInFooter?: boolean;
  fillParentHeight?: boolean;
  activeTool?: DrawingTool;
  onToolChange?: (tool: DrawingTool) => void;
  backgroundContent?: React.ReactNode;
  canvasMinHeightClassName?: string;
}

export const NotesCanvas: React.FC<NotesCanvasProps> = ({
  initialText,
  initialDrawingJson,
  documentKey,
  placeholder,
  currentPage = 0,
  totalPages = 1,
  onPageChange,
  onSave,
  onAddPage,
  onDeletePage,
  canDeletePage = false,
  mode = 'freeform',
  showText = true,
  toolset = 'advanced',
  allowPagination = true,
  showSaveButton = true,
  onDraftChange,
  embedded = false,
  toolbarDockedToBorder = false,
  toolbarOffsetClassName,
  toolbarPlacement = 'bottom-center',
  toolbarInFooter = false,
  fillParentHeight = false,
  activeTool,
  onToolChange,
  backgroundContent,
  canvasMinHeightClassName,
}) => {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const currentStrokeRef = useRef<DrawingStroke | null>(null);
  const lastHydratedDocumentKeyRef = useRef('');
  const lastExternalToolRef = useRef<DrawingTool | undefined>(activeTool);

  const [tool, setTool] = useState<DrawingTool>(activeTool || 'pen');
  const [penColor, setPenColor] = useState('#111827');
  const [penSize, setPenSize] = useState(2);
  const [highlighterColor, setHighlighterColor] = useState('#FDE047');
  const [highlighterSize, setHighlighterSize] = useState(10);
  const [eraserSize, setEraserSize] = useState(18);
  const [text, setText] = useState(initialText);
  const [strokes, setStrokes] = useState<DrawingStroke[]>([]);
  const [isDirty, setIsDirty] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [saveLabel, setSaveLabel] = useState<'idle' | 'saved' | 'error'>('idle');
  const [showColorPalette, setShowColorPalette] = useState(false);
  const [showTextModal, setShowTextModal] = useState(false);
  const [textModalVisible, setTextModalVisible] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [floatingPos, setFloatingPos] = useState<{ x: number; y: number } | null>(null);
  const [floatingSize, setFloatingSize] = useState<{ w: number; h: number }>({ w: 420, h: 340 });
  const [textAreaHeight, setTextAreaHeight] = useState<number>(92);
  const splitRef = useRef<{ startY: number; originH: number } | null>(null);
  const outerContainerRef = useRef<HTMLDivElement>(null);
  const dragRef = useRef<{ startX: number; startY: number; originX: number; originY: number } | null>(null);
  const resizeRef = useRef<{ startX: number; startY: number; originW: number; originH: number } | null>(null);
  const floatingNodeRef = useRef<HTMLDivElement>(null);

  const openTextModal = useCallback(() => {
    if (!floatingPos) {
      setFloatingPos({ x: Math.max(60, window.innerWidth / 2 - 210), y: Math.max(40, window.innerHeight / 2 - 200) });
    }
    setShowTextModal(true);
    requestAnimationFrame(() => {
      requestAnimationFrame(() => setTextModalVisible(true));
    });
  }, [floatingPos]);

  const closeTextModal = useCallback(() => {
    setTextModalVisible(false);
    setIsFullscreen(false);
    setTimeout(() => setShowTextModal(false), 280);
  }, []);

  const handleDragStart = useCallback((e: React.PointerEvent) => {
    if (isFullscreen) return;
    e.preventDefault();
    e.stopPropagation();
    const pos = floatingPos || { x: 60, y: 40 };
    dragRef.current = { startX: e.clientX, startY: e.clientY, originX: pos.x, originY: pos.y };
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  }, [floatingPos, isFullscreen]);

  const handleDragMove = useCallback((e: React.PointerEvent) => {
    if (!dragRef.current) return;
    e.preventDefault();
    const dx = e.clientX - dragRef.current.startX;
    const dy = e.clientY - dragRef.current.startY;
    setFloatingPos({
      x: Math.max(0, Math.min(window.innerWidth - 120, dragRef.current.originX + dx)),
      y: Math.max(0, Math.min(window.innerHeight - 60, dragRef.current.originY + dy)),
    });
  }, []);

  const handleDragEnd = useCallback(() => {
    dragRef.current = null;
  }, []);

  const handleResizeStart = useCallback((e: React.PointerEvent) => {
    if (isFullscreen) return;
    e.preventDefault();
    e.stopPropagation();
    resizeRef.current = { startX: e.clientX, startY: e.clientY, originW: floatingSize.w, originH: floatingSize.h };
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  }, [floatingSize, isFullscreen]);

  const handleResizeMove = useCallback((e: React.PointerEvent) => {
    if (!resizeRef.current) return;
    e.preventDefault();
    const dw = e.clientX - resizeRef.current.startX;
    const dh = e.clientY - resizeRef.current.startY;
    setFloatingSize({
      w: Math.max(280, Math.min(window.innerWidth - 40, resizeRef.current.originW + dw)),
      h: Math.max(200, Math.min(window.innerHeight - 40, resizeRef.current.originH + dh)),
    });
  }, []);

  const handleResizeEnd = useCallback(() => {
    resizeRef.current = null;
  }, []);

  const handleSplitStart = useCallback((e: React.PointerEvent) => {
    e.preventDefault();
    e.stopPropagation();
    splitRef.current = { startY: e.clientY, originH: textAreaHeight };
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
  }, [textAreaHeight]);

  const handleSplitMove = useCallback((e: React.PointerEvent) => {
    if (!splitRef.current) return;
    e.preventDefault();
    const dy = e.clientY - splitRef.current.startY;
    const containerRect = outerContainerRef.current?.getBoundingClientRect();
    // Reserve ~88px at the bottom for the drawing toolbar so it stays fixed in place
    const TOOLBAR_RESERVED = 88;
    const maxH = containerRect ? Math.max(60, containerRect.height - TOOLBAR_RESERVED - 40) : 600;
    const next = Math.max(40, Math.min(maxH, splitRef.current.originH + dy));
    setTextAreaHeight(next);
  }, []);

  const handleSplitEnd = useCallback(() => {
    splitRef.current = null;
  }, []);
  const textRef = useRef(text);
  const strokesRef = useRef(strokes);
  const isDirtyRef = useRef(isDirty);

  const colorPresets = ['#111827', '#dc2626', '#ea580c', '#ca8a04', '#16a34a', '#2563eb', '#7c3aed', '#ec4899'];

  const availableTools = useMemo<DrawingTool[]>(() => {
    switch (toolset) {
      case 'quick':
        return ['pen', 'eraser'];
      case 'structured':
        return ['pen', 'line', 'rect', 'eraser'];
      default:
        return ['pen', 'highlighter', 'eraser'];
    }
  }, [toolset]);

  const effectiveDocumentKey = documentKey || `page:${currentPage}`;
  const serializeDrawing = React.useCallback((drawingStrokes: DrawingStroke[]) => JSON.stringify({
    version: 1,
    strokes: drawingStrokes,
  } satisfies DrawingDocument), []);
  const emitDraft = React.useCallback((next?: {
    text?: string;
    strokes?: DrawingStroke[];
    isDirty?: boolean;
  }) => {
    if (!onDraftChange) return;
    const draftText = next?.text ?? textRef.current;
    const draftStrokes = next?.strokes ?? strokesRef.current;
    const draftDirty = next?.isDirty ?? isDirtyRef.current;
    onDraftChange({
      text: draftText,
      drawingJson: serializeDrawing(draftStrokes),
      isDirty: draftDirty,
    });
  }, [onDraftChange, serializeDrawing]);

  useEffect(() => {
    const nextText = initialText || '';
    const nextDrawingJson = initialDrawingJson || EMPTY_DRAWING_JSON;
    const parsedDrawing = parseDrawingJson(nextDrawingJson);
    const isDocumentSwitch = lastHydratedDocumentKeyRef.current !== effectiveDocumentKey;

    if (!isDocumentSwitch && isDirty) {
      return;
    }

    setText(nextText);
    setStrokes(parsedDrawing);
    setIsDirty(false);
    setSaveLabel('idle');
    lastHydratedDocumentKeyRef.current = effectiveDocumentKey;
    textRef.current = nextText;
    strokesRef.current = parsedDrawing;
    isDirtyRef.current = false;
    emitDraft({
      text: textRef.current,
      strokes: strokesRef.current,
      isDirty: false,
    });
  }, [effectiveDocumentKey, emitDraft, initialDrawingJson, initialText, isDirty]);

  useEffect(() => {
    if (!availableTools.includes(tool)) {
      const fallbackTool = availableTools[0] || 'pen';
      setTool(fallbackTool);
      onToolChange?.(fallbackTool);
    }
  }, [availableTools, onToolChange, tool]);

  useEffect(() => {
    if (lastExternalToolRef.current === activeTool) return;
    lastExternalToolRef.current = activeTool;
    if (activeTool) {
      setTool(activeTool);
    }
  }, [activeTool]);

  const handleToolSelect = React.useCallback((nextTool: DrawingTool) => {
    if (nextTool === tool) return;
    setTool(nextTool);
    onToolChange?.(nextTool);
  }, [onToolChange, tool]);

  useEffect(() => {
    if (tool === 'eraser' || toolset === 'quick' || toolset === 'structured') {
      setShowColorPalette(false);
    }
  }, [tool, toolset]);

  useEffect(() => {
    const canvas = canvasRef.current;
    const container = containerRef.current;
    if (!canvas || !container) return;

    const resizeCanvas = () => {
      const rect = container.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const dpr = window.devicePixelRatio || 1;
      canvas.width = rect.width * dpr;
      canvas.height = rect.height * dpr;
      canvas.style.width = `${rect.width}px`;
      canvas.style.height = `${rect.height}px`;
      const ctx = canvas.getContext('2d');
      if (!ctx) return;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.scale(dpr, dpr);
      redraw(canvas, strokes);
    };

    resizeCanvas();
    const observer = new ResizeObserver(() => resizeCanvas());
    observer.observe(container);
    window.addEventListener('resize', resizeCanvas);
    return () => {
      observer.disconnect();
      window.removeEventListener('resize', resizeCanvas);
    };
  }, [strokes]);

  const pageIndicator = useMemo(
    () => `${currentPage + 1}/${Math.max(totalPages, 1)}`,
    [currentPage, totalPages],
  );

  const canvasBackgroundStyle = useMemo(
    () => (
      mode === 'grid'
        ? {
            backgroundColor: '#ffffff',
            backgroundImage:
              'linear-gradient(to right, rgba(148, 163, 184, 0.22) 1px, transparent 1px), linear-gradient(to bottom, rgba(148, 163, 184, 0.22) 1px, transparent 1px)',
            backgroundSize: '24px 24px',
          }
        : { backgroundColor: '#ffffff' }
    ),
    [mode],
  );

  const drawingJson = useMemo(
    () => serializeDrawing(strokes),
    [serializeDrawing, strokes],
  );

  useEffect(() => {
    textRef.current = text;
  }, [text]);

  useEffect(() => {
    strokesRef.current = strokes;
  }, [strokes]);

  useEffect(() => {
    isDirtyRef.current = isDirty;
  }, [isDirty]);

  const currentColor = toolset === 'advanced'
    ? (tool === 'highlighter' ? highlighterColor : penColor)
    : '#111827';
  const currentSize = tool === 'eraser'
    ? eraserSize
    : tool === 'highlighter'
      ? highlighterSize
      : penSize;

  const commitPreview = () => {
    const stroke = currentStrokeRef.current;
    if (!stroke) return;
    currentStrokeRef.current = null;
    setStrokes((previous) => {
      const next = [...previous, normalizeStroke(stroke)];
      strokesRef.current = next;
      emitDraft({ strokes: next, isDirty: true });
      return next;
    });
  };

  const drawPreview = (previewStroke: DrawingStroke | null) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    redraw(canvas, previewStroke ? [...strokes, normalizeStroke(previewStroke)] : strokes);
  };

  const handlePointerDown = (event: React.PointerEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const point = toNormalizedPoint(event, canvas);
    currentStrokeRef.current = {
      tool,
      color: currentColor,
      size: currentSize,
      points: [point],
    };
    setIsDirty(true);
    isDirtyRef.current = true;
    setSaveLabel('idle');
    event.currentTarget.setPointerCapture?.(event.pointerId);

    if (tool === 'pen' || tool === 'highlighter' || tool === 'eraser') {
      drawPreview(currentStrokeRef.current);
    }
  };

  const handlePointerMove = (event: React.PointerEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current;
    const stroke = currentStrokeRef.current;
    if (!canvas || !stroke) return;

    const point = toNormalizedPoint(event, canvas);
    if (stroke.tool === 'pen' || stroke.tool === 'highlighter' || stroke.tool === 'eraser') {
      stroke.points.push(point);
    } else {
      stroke.points = [stroke.points[0], point];
    }

    drawPreview(stroke);
  };

  const handlePointerUp = (event: React.PointerEvent<HTMLCanvasElement>) => {
    event.currentTarget.releasePointerCapture?.(event.pointerId);
    commitPreview();
  };

  const handleClear = () => {
    setStrokes([]);
    strokesRef.current = [];
    setIsDirty(true);
    isDirtyRef.current = true;
    setSaveLabel('idle');
    emitDraft({ strokes: [], isDirty: true });
  };

  const handleSave = async () => {
    setIsDirty(false);
    isDirtyRef.current = false;
    setSaveLabel('saved');
    emitDraft({ isDirty: false });
    void onSave({
      text,
      drawingJson,
      previewDataUrl: buildNotePreviewDataUrlFromContent({
        text,
        drawingJson,
        mode: mode as 'freeform' | 'grid',
      }),
    }).catch((error) => {
      console.error('Failed to save note page', error);
      setSaveLabel('error');
    });
  };

  const toolbarContent = (
    <div className="relative flex items-center gap-2 rounded-[40px] border border-[#907CA1] bg-white/95 px-3 py-2 shadow-lg backdrop-blur">
      {showColorPalette && toolset === 'advanced' && tool !== 'eraser' && (
        <div className={`absolute left-1/2 flex -translate-x-1/2 items-center gap-2 rounded-[32px] border border-[#907CA1]/40 bg-white/95 px-3 py-2 shadow-lg backdrop-blur ${
          toolbarPlacement === 'top-right'
            ? 'top-full mt-3'
            : 'bottom-full mb-3'
        }`}>
          {colorPresets.map((color) => (
            <button
              key={color}
              type="button"
              title={`Couleur ${color}`}
              aria-label={`Choisir la couleur ${color}`}
              onClick={() => {
                if (tool === 'highlighter') setHighlighterColor(color);
                else setPenColor(color);
                setIsDirty(true);
                setShowColorPalette(false);
              }}
              className={`h-7 w-7 rounded-full border-2 transition-transform hover:scale-105 ${
                (tool === 'highlighter' ? highlighterColor : penColor) === color ? 'border-slate-900' : 'border-white'
              }`}
              style={{ backgroundColor: color }}
            />
          ))}
        </div>
      )}

      <ToolButton
        label="Crayon"
        icon={<PenLine size={18} />}
        isActive={tool === 'pen'}
        onClick={() => handleToolSelect('pen')}
      />
      {toolset === 'advanced' && (
        <ToolButton
          label="Surligneur"
          icon={<Highlighter size={18} />}
          isActive={tool === 'highlighter'}
          onClick={() => handleToolSelect('highlighter')}
        />
      )}
      {toolset === 'structured' && (
        <>
          <ToolButton
            label="Ligne"
            icon={<Slash size={18} />}
            isActive={tool === 'line'}
            onClick={() => handleToolSelect('line')}
          />
          <ToolButton
            label="Rectangle"
            icon={<RectangleHorizontal size={18} />}
            isActive={tool === 'rect'}
            onClick={() => handleToolSelect('rect')}
          />
        </>
      )}
      <ToolButton
        label="Gomme"
        icon={<Eraser size={18} />}
        isActive={tool === 'eraser'}
        onClick={() => handleToolSelect('eraser')}
      />
      {toolset === 'advanced' && tool !== 'eraser' && (
        <ToolButton
          label="Couleurs"
          icon={<Palette size={18} />}
          isActive={showColorPalette}
          onClick={() => setShowColorPalette((value) => !value)}
          accentColor={tool === 'highlighter' ? highlighterColor : penColor}
        />
      )}
      <ToolButton
        label="Effacer"
        icon={<Trash2 size={18} />}
        isActive={false}
        onClick={handleClear}
      />
      {showSaveButton && (
        <ToolButton
          label={isSaving ? 'Sauvegarde' : 'Sauvegarder'}
          icon={<Save size={18} className={isSaving ? 'animate-pulse' : ''} />}
          isActive={saveLabel === 'saved'}
          onClick={() => void handleSave()}
          disabled={isSaving || !isDirty}
        />
      )}
    </div>
  );

  return (
    <div
      ref={outerContainerRef}
      className={`flex-1 flex flex-col bg-white ${
        fillParentHeight ? 'h-full min-h-0' : 'min-h-[460px]'
      } ${
        embedded ? '' : 'rounded-b-3xl shadow-sm border-x border-b border-slate-200'
      }`}
    >
      {showText && (
        <div
          className="relative px-4 pt-4 pb-3 border-b border-slate-200 bg-slate-50"
          style={{ height: textAreaHeight + 28 }}
        >
          <textarea
            value={text}
            onChange={(event) => {
              const nextText = event.target.value;
              setText(nextText);
              textRef.current = nextText;
              setIsDirty(true);
              isDirtyRef.current = true;
              setSaveLabel('idle');
              emitDraft({ text: nextText, isDirty: true });
            }}
            placeholder={placeholder}
            className="w-full rounded-2xl border border-slate-200 bg-white px-4 py-3 text-slate-700 outline-none focus:ring-2 focus:ring-[#907CA1] resize-none"
            style={{ height: textAreaHeight }}
          />
          <button
            type="button"
            onClick={openTextModal}
            className="absolute bottom-5 left-5 p-1.5 rounded-lg text-slate-400 hover:text-slate-600 hover:bg-white/80 transition-colors"
            title="Ouvrir en grand"
          >
            <Maximize2 size={16} />
          </button>
        </div>
      )}

      {showText && (
        <div
          className="relative flex items-center justify-center h-2 bg-slate-100 hover:bg-[#907CA1]/20 transition-colors group"
          style={{ cursor: 'ns-resize', touchAction: 'none' }}
          onPointerDown={handleSplitStart}
          onPointerMove={handleSplitMove}
          onPointerUp={handleSplitEnd}
          onPointerCancel={handleSplitEnd}
          title="Glisser pour redimensionner"
        >
          <div className="h-0.5 w-12 rounded-full bg-slate-300 group-hover:bg-[#907CA1] transition-colors" />
        </div>
      )}

      {showTextModal && (
        <div
          ref={floatingNodeRef}
          className={`fixed z-[9999] flex flex-col bg-white rounded-2xl shadow-2xl border border-[#907CA1]/30 overflow-hidden transition-all ease-out ${
            isFullscreen
              ? 'inset-3 !w-auto !h-auto'
              : ''
          } ${textModalVisible ? 'opacity-100 scale-100' : 'opacity-0 scale-90'}`}
          style={isFullscreen ? { transition: 'opacity 200ms, transform 200ms, inset 250ms' } : {
            left: floatingPos?.x ?? 60,
            top: floatingPos?.y ?? 40,
            width: floatingSize.w,
            height: floatingSize.h,
            transition: 'opacity 200ms, transform 200ms',
          }}
        >
          {/* Draggable header / tab bar */}
          <div
            className="flex items-center justify-between px-4 py-2.5 border-b border-slate-200 bg-gradient-to-r from-[#907CA1]/10 to-slate-50 select-none"
            style={{ cursor: isFullscreen ? 'default' : 'grab', touchAction: 'none' }}
            onPointerDown={handleDragStart}
            onPointerMove={handleDragMove}
            onPointerUp={handleDragEnd}
          >
            <div className="flex items-center gap-2">
              <GripHorizontal size={16} className="text-[#907CA1]/50" />
              <span className="text-xs font-bold text-[#907CA1] uppercase tracking-wider">Notes</span>
            </div>
            <div className="flex items-center gap-1">
              <button
                type="button"
                onClick={() => setIsFullscreen((v) => !v)}
                className="p-1.5 rounded-lg hover:bg-slate-200/70 transition-colors"
                title={isFullscreen ? 'Réduire' : 'Plein écran'}
              >
                {isFullscreen ? <Minimize2 size={15} className="text-slate-500" /> : <Maximize2 size={15} className="text-slate-500" />}
              </button>
              <button
                type="button"
                onClick={closeTextModal}
                className="p-1.5 rounded-lg hover:bg-red-100 transition-colors"
                title="Fermer"
              >
                <X size={15} className="text-slate-500" />
              </button>
            </div>
          </div>
          {/* Text area */}
          <textarea
            autoFocus
            value={text}
            onChange={(event) => {
              const nextText = event.target.value;
              setText(nextText);
              textRef.current = nextText;
              setIsDirty(true);
              isDirtyRef.current = true;
              setSaveLabel('idle');
              emitDraft({ text: nextText, isDirty: true });
            }}
            placeholder={placeholder}
            className="flex-1 w-full p-4 text-sm leading-relaxed text-slate-700 outline-none resize-none"
          />
          {/* Resize handle (bottom-right corner) */}
          {!isFullscreen && (
            <div
              className="absolute bottom-0 right-0 w-5 h-5 cursor-nwse-resize"
              style={{ touchAction: 'none' }}
              onPointerDown={handleResizeStart}
              onPointerMove={handleResizeMove}
              onPointerUp={handleResizeEnd}
            >
              <svg viewBox="0 0 20 20" className="w-full h-full text-slate-300">
                <path d="M14 20L20 14M10 20L20 10M6 20L20 6" stroke="currentColor" strokeWidth="1.5" fill="none" />
              </svg>
            </div>
          )}
        </div>
      )}

      <div
        ref={containerRef}
        className={`relative flex-1 ${fillParentHeight ? 'min-h-0' : (showText ? 'min-h-[88px]' : 'min-h-[340px]')} ${canvasMinHeightClassName || ''}`.trim()}
        style={canvasBackgroundStyle}
      >
        {backgroundContent && (
          <div
            className="absolute inset-0 pointer-events-none select-none"
            style={{
              WebkitUserSelect: 'none',
              userSelect: 'none',
              WebkitUserDrag: 'none',
              WebkitTouchCallout: 'none',
            }}
          >
            {backgroundContent}
          </div>
        )}
        <canvas
          ref={canvasRef}
          className="absolute inset-0 touch-none cursor-crosshair"
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={handlePointerUp}
          onPointerLeave={handlePointerUp}
        />

        {!toolbarInFooter && (
          <div
            className={`absolute z-10 ${
              toolbarPlacement === 'top-right'
                ? 'top-4 right-4'
                : `left-1/2 -translate-x-1/2 ${toolbarDockedToBorder ? 'bottom-0 translate-y-1/2' : 'bottom-4'}`
            } ${toolbarOffsetClassName || ''}`.trim()}
          >
            {toolbarContent}
          </div>
        )}

        {allowPagination && onPageChange && (
          <div className="absolute bottom-4 right-4 z-10">
            <div className="flex items-center gap-0.5 rounded-[22px] border border-slate-200 bg-white/95 px-1.5 py-1.5 shadow-lg backdrop-blur">
              <PageButton
                onClick={() => onPageChange(Math.max(0, currentPage - 1))}
                disabled={currentPage <= 0}
                icon={<ArrowLeft size={16} />}
                title="Page précédente"
              />
              <span className="min-w-[42px] text-center text-[10px] font-bold tracking-wide text-slate-500">
                {pageIndicator}
              </span>
              <PageButton
                onClick={() => onPageChange(Math.min(totalPages - 1, currentPage + 1))}
                disabled={currentPage >= totalPages - 1}
                icon={<ArrowRight size={16} />}
                title="Page suivante"
              />
            </div>
          </div>
        )}

        {(onAddPage || onDeletePage) && (
          <div className="absolute top-4 right-4 z-10 flex items-center gap-1 rounded-[22px] border border-[#907CA1] bg-white/95 px-1.5 py-1.5 shadow-lg backdrop-blur">
            {onAddPage && (
              <PageButton
                onClick={() => void onAddPage()}
                icon={<Plus size={16} />}
                title="Ajouter une page"
              />
            )}
            {onDeletePage && (
              <PageButton
                onClick={() => void onDeletePage()}
                icon={<Trash2 size={16} />}
                disabled={!canDeletePage}
                title="Supprimer la page"
              />
            )}
          </div>
        )}
      </div>

      {toolbarInFooter && (
        <div className="border-t border-slate-200 bg-white px-4 py-3">
          <div className="flex justify-center">
            {toolbarContent}
          </div>
        </div>
      )}
    </div>
  );
};

const ToolButton: React.FC<{
  label: string;
  icon: React.ReactNode;
  isActive: boolean;
  onClick: () => void;
  disabled?: boolean;
  accentColor?: string;
}> = ({ label, icon, isActive, onClick, disabled = false, accentColor }) => (
  <button
    type="button"
    onPointerDown={(event) => event.stopPropagation()}
    onClick={(event) => {
      event.stopPropagation();
      onClick();
    }}
    disabled={disabled}
    title={label}
    aria-label={label}
    className={`relative inline-flex items-center justify-center h-11 w-11 rounded-full text-sm font-semibold transition-colors disabled:opacity-40 disabled:cursor-not-allowed ${
      isActive
        ? 'bg-[#D8D0DC] text-[#554A63]'
        : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
    }`}
  >
    {icon}
    {accentColor && (
      <span
        className="absolute -top-0.5 -right-0.5 h-3.5 w-3.5 rounded-full border-2 border-white"
        style={{ backgroundColor: accentColor }}
      />
    )}
  </button>
);

const PageButton: React.FC<{
  onClick: () => void;
  icon: React.ReactNode;
  disabled?: boolean;
  title?: string;
}> = ({ onClick, icon, disabled = false, title }) => (
  <button
    type="button"
    onPointerDown={(event) => event.stopPropagation()}
    onClick={(event) => {
      event.stopPropagation();
      onClick();
    }}
    disabled={disabled}
    title={title}
    className="w-8 h-8 rounded-full border border-slate-200 flex items-center justify-center text-slate-600 hover:bg-slate-50 disabled:opacity-40"
  >
    {icon}
  </button>
);

const EMPTY_DRAWING_JSON = JSON.stringify({ version: 1, strokes: [] });

const parseDrawingJson = (rawValue?: string | null): DrawingStroke[] => {
  if (!rawValue) return [];
  try {
    const parsed = JSON.parse(rawValue) as DrawingDocument | DrawingStroke[];
    const strokes = Array.isArray(parsed) ? parsed : Array.isArray(parsed?.strokes) ? parsed.strokes : [];
    return strokes
      .filter((stroke) => Array.isArray(stroke?.points))
      .map((stroke) => normalizeStroke(stroke));
  } catch {
    return [];
  }
};

const normalizeStroke = (stroke: DrawingStroke): DrawingStroke => ({
  ...stroke,
  color: stroke.color || '#111827',
  size: Number(stroke.size) || 2,
  points: Array.isArray(stroke.points) ? stroke.points.slice(0, 2_000) : [],
});

const toNormalizedPoint = (
  event: React.PointerEvent<HTMLCanvasElement>,
  canvas: HTMLCanvasElement,
): DrawingPoint => {
  const rect = canvas.getBoundingClientRect();
  return {
    x: (event.clientX - rect.left) / rect.width,
    y: (event.clientY - rect.top) / rect.height,
  };
};

const redraw = (
  canvas: HTMLCanvasElement,
  strokes: DrawingStroke[],
) => {
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  const rect = canvas.getBoundingClientRect();
  ctx.clearRect(0, 0, rect.width, rect.height);

  for (const stroke of strokes) {
    if (!stroke.points.length) continue;
    const points = stroke.points.map((point) => ({
      x: point.x * rect.width,
      y: point.y * rect.height,
    }));

    ctx.save();
    ctx.beginPath();
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.lineWidth = stroke.size;
    ctx.strokeStyle = stroke.tool === 'eraser' ? '#000000' : (stroke.color || '#111827');
    ctx.globalCompositeOperation = stroke.tool === 'eraser' ? 'destination-out' : 'source-over';
    ctx.globalAlpha = stroke.tool === 'highlighter' ? 0.4 : 1;

    if (stroke.tool === 'rect' && points.length >= 2) {
      const start = points[0];
      const end = points[points.length - 1];
      const width = end.x - start.x;
      const height = end.y - start.y;
      ctx.strokeRect(start.x, start.y, width, height);
    } else if (stroke.tool === 'line' && points.length >= 2) {
      const start = points[0];
      const end = points[points.length - 1];
      ctx.moveTo(start.x, start.y);
      ctx.lineTo(end.x, end.y);
      ctx.stroke();
    } else {
      const [firstPoint, ...otherPoints] = points;
      ctx.moveTo(firstPoint.x, firstPoint.y);
      for (const point of otherPoints) {
        ctx.lineTo(point.x, point.y);
      }
      if (otherPoints.length === 0) {
        ctx.lineTo(firstPoint.x + 0.01, firstPoint.y + 0.01);
      }
      ctx.stroke();
    }

    ctx.restore();
  }
};

const buildNotePreviewDataUrl = ({
  text,
  strokes,
  mode,
}: {
  text: string;
  strokes: DrawingStroke[];
  mode: 'freeform' | 'grid';
}): string => {
  if (typeof document === 'undefined') {
    return '';
  }

  const canvas = document.createElement('canvas');
  const width = 360;
  const height = 220;
  const padding = 18;
  const textAreaHeight = 78;
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d');
  if (!ctx) return '';

  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, width, height);

  if (mode === 'grid') {
    ctx.strokeStyle = 'rgba(148, 163, 184, 0.18)';
    ctx.lineWidth = 1;
    for (let x = 0; x <= width; x += 24) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height);
      ctx.stroke();
    }
    for (let y = 0; y <= height; y += 24) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
      ctx.stroke();
    }
  }

  const normalizedText = String(text || '').replace(/\s+/g, ' ').trim();
  const previewLines = normalizedText
    ? wrapPreviewText(normalizedText, 36).slice(0, 3)
    : ['Note manuscrite'];

  ctx.fillStyle = normalizedText ? '#111827' : '#94a3b8';
  ctx.font = '600 14px sans-serif';
  previewLines.forEach((line, index) => {
    ctx.fillText(line, padding, padding + 18 + index * 18);
  });

  const previewArea = {
    x: padding,
    y: padding + textAreaHeight,
    width: width - padding * 2,
    height: height - padding * 2 - textAreaHeight,
  };

  ctx.save();
  ctx.beginPath();
  ctx.rect(previewArea.x, previewArea.y, previewArea.width, previewArea.height);
  ctx.clip();

  for (const rawStroke of strokes) {
    const stroke = normalizeStroke(rawStroke);
    if (!stroke.points.length) continue;
    const points = stroke.points.map((point) => ({
      x: previewArea.x + point.x * previewArea.width,
      y: previewArea.y + point.y * previewArea.height,
    }));

    ctx.save();
    ctx.beginPath();
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.lineWidth = stroke.size;
    ctx.strokeStyle = stroke.tool === 'eraser' ? '#000000' : (stroke.color || '#111827');
    ctx.globalCompositeOperation = stroke.tool === 'eraser' ? 'destination-out' : 'source-over';
    ctx.globalAlpha = stroke.tool === 'highlighter' ? 0.4 : 1;

    if (stroke.tool === 'rect' && points.length >= 2) {
      const start = points[0];
      const end = points[points.length - 1];
      ctx.strokeRect(start.x, start.y, end.x - start.x, end.y - start.y);
    } else if (stroke.tool === 'line' && points.length >= 2) {
      ctx.moveTo(points[0].x, points[0].y);
      ctx.lineTo(points[points.length - 1].x, points[points.length - 1].y);
      ctx.stroke();
    } else {
      const [firstPoint, ...otherPoints] = points;
      ctx.moveTo(firstPoint.x, firstPoint.y);
      for (const point of otherPoints) {
        ctx.lineTo(point.x, point.y);
      }
      if (otherPoints.length === 0) {
        ctx.lineTo(firstPoint.x + 0.01, firstPoint.y + 0.01);
      }
      ctx.stroke();
    }

    ctx.restore();
  }

  ctx.restore();

  ctx.strokeStyle = '#e2e8f0';
  ctx.lineWidth = 1;
  ctx.strokeRect(0.5, 0.5, width - 1, height - 1);

  return canvas.toDataURL('image/png', 0.82);
};

export const buildNotePreviewDataUrlFromContent = ({
  text,
  drawingJson,
  mode,
}: {
  text: string;
  drawingJson: string;
  mode: 'freeform' | 'grid';
}): string => buildNotePreviewDataUrl({
  text,
  strokes: parseDrawingJson(drawingJson || EMPTY_DRAWING_JSON),
  mode,
});

const wrapPreviewText = (value: string, maxCharactersPerLine: number): string[] => {
  const words = String(value || '').trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [];

  const lines: string[] = [];
  let currentLine = '';

  for (const word of words) {
    const nextLine = currentLine ? `${currentLine} ${word}` : word;
    if (nextLine.length <= maxCharactersPerLine) {
      currentLine = nextLine;
      continue;
    }
    if (currentLine) {
      lines.push(currentLine);
    }
    currentLine = word;
  }

  if (currentLine) {
    lines.push(currentLine);
  }

  return lines;
};

import React, { useState, useRef, useEffect, useCallback } from 'react';
import { PenLine, Eraser, Minus, Square, Trash2, Download } from 'lucide-react';

// Grid constants
const RULER_SIZE = 36;      // px — width/height of the ruler strips
const CELL_CM = 20;         // 1 cell = 20 cm in real world
const CELLS_PER_MAJOR = 5;  // major grid line every 5 cells (every 100cm)

interface PlanCanvasProps {
    initialDrawingUrl?: string | null;
    onSave: (blob: Blob) => void;
}

type DrawTool = 'pen' | 'eraser' | 'line' | 'rect';

export const PlanCanvas: React.FC<PlanCanvasProps> = ({ initialDrawingUrl, onSave }) => {
    const containerRef = useRef<HTMLDivElement>(null);
    const canvasRef = useRef<HTMLCanvasElement>(null);       // main drawing
    const overlayRef = useRef<HTMLCanvasElement>(null);      // ruler + grid overlay
    const previewRef = useRef<HTMLCanvasElement>(null);      // line/rect preview
    const rafRef = useRef<number>(0);

    const [tool, setTool] = useState<DrawTool>('pen');
    const [penColor, setPenColor] = useState('#1a1a1a');
    const [penSize, setPenSize] = useState(2);
    const [showTools, setShowTools] = useState<string | null>(null);

    const isDrawing = useRef(false);
    const startPoint = useRef<{ x: number; y: number } | null>(null);
    const lastPoint = useRef<{ x: number; y: number } | null>(null);
    const lastMid = useRef<{ x: number; y: number } | null>(null);
    const isDirty = useRef(false);

    // ─── canvas size ────────────────────────────────────────────────────────────
    const [canvasSize, setCanvasSize] = useState({ w: 0, h: 0 });

    const getCanvasCoords = (e: React.MouseEvent | React.TouchEvent) => {
        const canvas = canvasRef.current;
        if (!canvas) return { x: 0, y: 0 };
        const rect = canvas.getBoundingClientRect();
        const clientX = 'touches' in e ? e.touches[0].clientX : e.clientX;
        const clientY = 'touches' in e ? e.touches[0].clientY : e.clientY;
        return {
            x: clientX - rect.left,
            y: clientY - rect.top,
        };
    };

    // ─── Draw the ruler + grid overlay onto overlayRef ──────────────────────────
    const drawOverlay = useCallback((w: number, h: number, cellPx: number) => {
        const canvas = overlayRef.current;
        if (!canvas) return;
        const dpr = window.devicePixelRatio || 1;
        canvas.width = w * dpr;
        canvas.height = h * dpr;
        canvas.style.width = `${w}px`;
        canvas.style.height = `${h}px`;
        const ctx = canvas.getContext('2d')!;
        ctx.scale(dpr, dpr);
        ctx.clearRect(0, 0, w, h);

        const drawW = w - RULER_SIZE;
        const drawH = h - RULER_SIZE;

        // Ruler backgrounds
        ctx.fillStyle = '#f4f6f8';
        ctx.fillRect(0, 0, w, RULER_SIZE);         // top ruler
        ctx.fillRect(0, 0, RULER_SIZE, h);         // left ruler
        ctx.fillStyle = '#e8ecf0';
        ctx.fillRect(0, 0, RULER_SIZE, RULER_SIZE); // corner

        // Grid
        const colsN = Math.ceil(drawW / cellPx);
        const rowsN = Math.ceil(drawH / cellPx);

        for (let c = 0; c <= colsN; c++) {
            const x = RULER_SIZE + c * cellPx;
            const isMajor = c % CELLS_PER_MAJOR === 0;
            ctx.strokeStyle = isMajor ? '#c8cfd8' : '#e2e6eb';
            ctx.lineWidth = isMajor ? 1 : 0.5;
            ctx.beginPath();
            ctx.moveTo(x, RULER_SIZE);
            ctx.lineTo(x, h);
            ctx.stroke();
        }
        for (let r = 0; r <= rowsN; r++) {
            const y = RULER_SIZE + r * cellPx;
            const isMajor = r % CELLS_PER_MAJOR === 0;
            ctx.strokeStyle = isMajor ? '#c8cfd8' : '#e2e6eb';
            ctx.lineWidth = isMajor ? 1 : 0.5;
            ctx.beginPath();
            ctx.moveTo(RULER_SIZE, y);
            ctx.lineTo(w, y);
            ctx.stroke();
        }

        // Ruler ticks & labels
        ctx.fillStyle = '#6b7a8d';
        ctx.font = `bold 9px system-ui, sans-serif`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';

        for (let c = 0; c <= colsN; c++) {
            const x = RULER_SIZE + c * cellPx;
            const cm = c * CELL_CM;
            const isMajor = c % CELLS_PER_MAJOR === 0;
            ctx.strokeStyle = '#9aa5b4';
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(x, isMajor ? RULER_SIZE - 10 : RULER_SIZE - 5);
            ctx.lineTo(x, RULER_SIZE);
            ctx.stroke();
            if (isMajor) {
                ctx.fillText(cm >= 100 ? `${cm}` : `${cm}`, x, RULER_SIZE / 2);
            }
        }

        ctx.textAlign = 'right';
        for (let r = 0; r <= rowsN; r++) {
            const y = RULER_SIZE + r * cellPx;
            const cm = r * CELL_CM;
            const isMajor = r % CELLS_PER_MAJOR === 0;
            ctx.strokeStyle = '#9aa5b4';
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(isMajor ? RULER_SIZE - 10 : RULER_SIZE - 5, y);
            ctx.lineTo(RULER_SIZE, y);
            ctx.stroke();
            if (isMajor) {
                ctx.save();
                ctx.translate(RULER_SIZE / 2, y);
                ctx.rotate(-Math.PI / 2);
                ctx.textAlign = 'center';
                ctx.fillText(`${cm}`, 0, 0);
                ctx.restore();
            }
        }

        // Ruler border lines
        ctx.strokeStyle = '#bcc5d0';
        ctx.lineWidth = 1;
        ctx.strokeRect(0.5, 0.5, RULER_SIZE, h);
        ctx.strokeRect(0.5, 0.5, w, RULER_SIZE);
    }, []);

    // ─── Init / resize ──────────────────────────────────────────────────────────
    const initCanvases = useCallback(() => {
        const container = containerRef.current;
        const canvas = canvasRef.current;
        const preview = previewRef.current;
        if (!container || !canvas || !preview) return;

        const w = container.clientWidth;
        const h = container.clientHeight;
        if (w === 0 || h === 0) return;

        const dpr = window.devicePixelRatio || 1;
        const drawW = w - RULER_SIZE;
        const drawH = h - RULER_SIZE;

        // Compute cell size to fit ~20 major lines across
        const cellPx = Math.max(10, Math.round(drawW / 100 * 4));

        // Main drawing canvas (covers only the draw area, offset by ruler)
        canvas.width = drawW * dpr;
        canvas.height = drawH * dpr;
        canvas.style.width = `${drawW}px`;
        canvas.style.height = `${drawH}px`;
        canvas.style.left = `${RULER_SIZE}px`;
        canvas.style.top = `${RULER_SIZE}px`;

        const ctx = canvas.getContext('2d')!;
        ctx.scale(dpr, dpr);
        ctx.lineCap = 'round';
        ctx.lineJoin = 'round';

        // Preview
        preview.width = drawW * dpr;
        preview.height = drawH * dpr;
        preview.style.width = `${drawW}px`;
        preview.style.height = `${drawH}px`;
        preview.style.left = `${RULER_SIZE}px`;
        preview.style.top = `${RULER_SIZE}px`;

        setCanvasSize({ w, h });
        drawOverlay(w, h, cellPx);
    }, [drawOverlay]);

    useEffect(() => {
        const id = setTimeout(initCanvases, 50);
        const obs = new ResizeObserver(() => initCanvases());
        if (containerRef.current) obs.observe(containerRef.current);
        return () => { clearTimeout(id); obs.disconnect(); };
    }, [initCanvases]);

    // ─── Load existing drawing ──────────────────────────────────────────────────
    useEffect(() => {
        if (!initialDrawingUrl) return;
        const canvas = canvasRef.current;
        const ctx = canvas?.getContext('2d');
        if (!canvas || !ctx) return;
        const img = new Image();
        img.crossOrigin = 'anonymous';
        img.src = initialDrawingUrl;
        img.onload = () => {
            const rect = canvas.getBoundingClientRect();
            ctx.clearRect(0, 0, rect.width, rect.height);
            ctx.drawImage(img, 0, 0, rect.width, rect.height);
        };
    }, [initialDrawingUrl]);

    // ─── Auto-save (debounce 1s after last stroke) ──────────────────────────────
    const saveTimeout = useRef<ReturnType<typeof setTimeout>>();
    const triggerSave = useCallback(() => {
        clearTimeout(saveTimeout.current);
        saveTimeout.current = setTimeout(() => {
            const canvas = canvasRef.current;
            if (!canvas) return;
            canvas.toBlob(blob => { if (blob) onSave(blob); }, 'image/png');
            isDirty.current = false;
        }, 1000);
    }, [onSave]);

    // ─── Drawing handlers ───────────────────────────────────────────────────────
    const applyToolStyle = (ctx: CanvasRenderingContext2D) => {
        if (tool === 'eraser') {
            ctx.globalCompositeOperation = 'destination-out';
            ctx.lineWidth = 24;
        } else {
            ctx.globalCompositeOperation = 'source-over';
            ctx.strokeStyle = penColor;
            ctx.lineWidth = penSize;
        }
    };

    const onPointerDown = (e: React.MouseEvent | React.TouchEvent) => {
        e.preventDefault();
        const { x, y } = getCanvasCoords(e);
        isDrawing.current = true;
        isDirty.current = true;
        startPoint.current = { x, y };
        lastPoint.current = { x, y };
        lastMid.current = { x, y };

        if (tool === 'pen' || tool === 'eraser') {
            const ctx = canvasRef.current?.getContext('2d');
            if (!ctx) return;
            applyToolStyle(ctx);
            ctx.beginPath();
            ctx.moveTo(x, y);
            ctx.lineTo(x + 0.1, y);
            ctx.stroke();
        }
    };

    const onPointerMove = (e: React.MouseEvent | React.TouchEvent) => {
        if (!isDrawing.current) return;
        e.preventDefault();
        const { x, y } = getCanvasCoords(e);

        if (tool === 'pen' || tool === 'eraser') {
            const ctx = canvasRef.current?.getContext('2d');
            if (!ctx || !lastPoint.current || !lastMid.current) return;
            applyToolStyle(ctx);
            const mid = { x: (lastPoint.current.x + x) / 2, y: (lastPoint.current.y + y) / 2 };
            ctx.beginPath();
            ctx.moveTo(lastMid.current.x, lastMid.current.y);
            ctx.quadraticCurveTo(lastPoint.current.x, lastPoint.current.y, mid.x, mid.y);
            ctx.stroke();
            lastPoint.current = { x, y };
            lastMid.current = mid;
        } else {
            // Shape preview
            cancelAnimationFrame(rafRef.current);
            rafRef.current = requestAnimationFrame(() => {
                const pctx = previewRef.current?.getContext('2d');
                const preview = previewRef.current;
                if (!pctx || !preview || !startPoint.current) return;
                const dpr = window.devicePixelRatio || 1;
                pctx.save();
                pctx.setTransform(1, 0, 0, 1, 0, 0);
                pctx.clearRect(0, 0, preview.width, preview.height);
                pctx.restore();
                pctx.globalCompositeOperation = 'source-over';
                pctx.strokeStyle = penColor;
                pctx.lineWidth = penSize;
                pctx.beginPath();
                if (tool === 'line') {
                    pctx.moveTo(startPoint.current.x, startPoint.current.y);
                    pctx.lineTo(x, y);
                } else {
                    const rx = Math.min(startPoint.current.x, x);
                    const ry = Math.min(startPoint.current.y, y);
                    pctx.rect(rx, ry, Math.abs(x - startPoint.current.x), Math.abs(y - startPoint.current.y));
                }
                pctx.stroke();
            });
        }
    };

    const onPointerUp = (e: React.MouseEvent | React.TouchEvent) => {
        if (!isDrawing.current) return;
        isDrawing.current = false;
        const { x, y } = getCanvasCoords(e);

        if ((tool === 'line' || tool === 'rect') && startPoint.current) {
            const ctx = canvasRef.current?.getContext('2d');
            const pctx = previewRef.current?.getContext('2d');
            const preview = previewRef.current;
            if (ctx) {
                ctx.globalCompositeOperation = 'source-over';
                ctx.strokeStyle = penColor;
                ctx.lineWidth = penSize;
                ctx.beginPath();
                if (tool === 'line') {
                    ctx.moveTo(startPoint.current.x, startPoint.current.y);
                    ctx.lineTo(x, y);
                } else {
                    ctx.rect(
                        Math.min(startPoint.current.x, x),
                        Math.min(startPoint.current.y, y),
                        Math.abs(x - startPoint.current.x),
                        Math.abs(y - startPoint.current.y),
                    );
                }
                ctx.stroke();
            }
            // clear preview
            if (pctx && preview) {
                pctx.save(); pctx.setTransform(1, 0, 0, 1, 0, 0);
                pctx.clearRect(0, 0, preview.width, preview.height);
                pctx.restore();
            }
        }

        lastPoint.current = null;
        lastMid.current = null;
        startPoint.current = null;
        triggerSave();
    };

    const clearCanvas = () => {
        const canvas = canvasRef.current;
        const ctx = canvas?.getContext('2d');
        if (!canvas || !ctx) return;
        ctx.save();
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.restore();
        triggerSave();
    };

    const downloadPlan = () => {
        const canvas = canvasRef.current;
        if (!canvas) return;
        const link = document.createElement('a');
        link.download = 'plan-visite.png';
        link.href = canvas.toDataURL('image/png');
        link.click();
    };

    // ─── UI ─────────────────────────────────────────────────────────────────────
    const toolBtn = (t: DrawTool, icon: React.ReactNode, label: string) => (
        <button
            title={label}
            onClick={() => { setTool(t); setShowTools(null); }}
            className={`flex flex-col items-center gap-0.5 px-2 py-1 rounded-lg transition-all text-xs font-medium
                ${tool === t ? 'bg-[#597E8D] text-white shadow-md' : 'text-slate-500 hover:bg-slate-100'}`}
        >
            {icon}
            <span className="hidden sm:block">{label}</span>
        </button>
    );

    return (
        <div className="flex flex-col h-full gap-0">
            {/* Toolbar */}
            <div className="flex items-center gap-2 px-3 py-2 bg-white border-b border-slate-200 rounded-t-2xl flex-wrap">
                <span className="text-xs font-bold text-slate-400 uppercase tracking-wider mr-1">Outils</span>
                {toolBtn('pen', <PenLine size={16} />, 'Crayon')}
                {toolBtn('line', <Minus size={16} />, 'Ligne')}
                {toolBtn('rect', <Square size={16} />, 'Rectangle')}
                {toolBtn('eraser', <Eraser size={16} />, 'Gomme')}

                <div className="h-6 w-px bg-slate-200 mx-1" />

                {/* Color */}
                <div className="flex items-center gap-1">
                    <span className="text-xs text-slate-400">Couleur</span>
                    <div className="flex gap-1">
                        {['#1a1a1a', '#e53e3e', '#2b6cb0', '#2f855a', '#d69e2e'].map(c => (
                            <button key={c} onClick={() => setPenColor(c)}
                                className={`w-5 h-5 rounded-full border-2 transition-transform hover:scale-110 ${penColor === c ? 'border-[#597E8D] scale-125' : 'border-transparent'}`}
                                style={{ background: c }} />
                        ))}
                        <label className="w-5 h-5 rounded-full border-2 border-slate-300 overflow-hidden cursor-pointer hover:scale-110 transition-transform" title="Autre couleur">
                            <input type="color" value={penColor} onChange={e => setPenColor(e.target.value)} className="opacity-0 w-0 h-0" />
                            <span className="block w-full h-full" style={{ background: penColor }} />
                        </label>
                    </div>
                </div>

                <div className="h-6 w-px bg-slate-200 mx-1" />

                {/* Size */}
                <div className="flex items-center gap-1.5 min-w-[100px]">
                    <span className="text-xs text-slate-400 whitespace-nowrap">Épaisseur</span>
                    <input type="range" min={1} max={10} value={penSize}
                        onChange={e => setPenSize(parseInt(e.target.value))}
                        className="w-20 accent-[#597E8D]" />
                    <span className="text-xs text-slate-500 w-4">{penSize}</span>
                </div>

                <div className="ml-auto flex gap-1">
                    <button onClick={downloadPlan} title="Télécharger le plan (PNG)"
                        className="p-1.5 text-slate-400 hover:text-[#597E8D] hover:bg-slate-100 rounded-lg transition-all">
                        <Download size={16} />
                    </button>
                    <button onClick={clearCanvas} title="Effacer tout"
                        className="p-1.5 text-slate-400 hover:text-red-500 hover:bg-red-50 rounded-lg transition-all">
                        <Trash2 size={16} />
                    </button>
                </div>
            </div>

            {/* Canvas area */}
            <div
                ref={containerRef}
                className="relative flex-1 overflow-hidden bg-white rounded-b-2xl border border-slate-200 border-t-0 select-none"
                style={{ minHeight: 480 }}
            >
                {/* Ruler overlay (pointer-events-none) */}
                <canvas
                    ref={overlayRef}
                    className="absolute inset-0 pointer-events-none z-10"
                    style={{ width: canvasSize.w, height: canvasSize.h }}
                />

                {/* Main drawing canvas */}
                <canvas
                    ref={canvasRef}
                    className="absolute z-20"
                    style={{ cursor: tool === 'eraser' ? 'cell' : 'crosshair' }}
                    onMouseDown={onPointerDown}
                    onMouseMove={onPointerMove}
                    onMouseUp={onPointerUp}
                    onMouseLeave={onPointerUp}
                    onTouchStart={onPointerDown}
                    onTouchMove={onPointerMove}
                    onTouchEnd={onPointerUp}
                />

                {/* Shape preview canvas */}
                <canvas
                    ref={previewRef}
                    className="absolute z-30 pointer-events-none"
                />

                {/* Scale legend */}
                <div className="absolute bottom-3 right-3 z-40 bg-white/80 border border-slate-200 rounded-lg px-2 py-1 text-xs text-slate-500 select-none pointer-events-none">
                    1 carreau = {CELL_CM} cm
                </div>
            </div>
        </div>
    );
};

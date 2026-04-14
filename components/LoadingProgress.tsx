import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Loader2 } from 'lucide-react';

type LoadingProgressProps = {
  label: string;
  hint?: string;
  variant?: 'page' | 'inline' | 'button';
  className?: string;
  complete?: boolean;
  onComplete?: () => void;
};

type SmoothLoadingOptions = {
  minVisibleMs?: number;
};

const LOADER_CYCLE_MS = 520;
const FINAL_FILL_MS = 360;

const getProgressFromElapsed = (elapsed: number) => {
  if (elapsed <= 0) return 10;
  if (elapsed >= LOADER_CYCLE_MS) return 100;

  const ratio = elapsed / LOADER_CYCLE_MS;
  const eased = 1 - Math.pow(1 - ratio, 2.4);
  return Math.min(100, 10 + eased * 90);
};

export const useSmoothLoadingState = (
  active: boolean,
  { minVisibleMs = LOADER_CYCLE_MS }: SmoothLoadingOptions = {},
) => {
  const [visible, setVisible] = useState(active);
  const [complete, setComplete] = useState(false);
  const startedAtRef = useRef(active ? performance.now() : 0);

  useEffect(() => {
    let timeoutId: number | undefined;

    if (active) {
      startedAtRef.current = performance.now();
      setVisible(true);
      setComplete(false);
      return undefined;
    }

    if (!visible) {
      return undefined;
    }

    const elapsed = startedAtRef.current ? performance.now() - startedAtRef.current : minVisibleMs;
    const remaining = Math.max(0, minVisibleMs - elapsed);
    timeoutId = window.setTimeout(() => {
      setComplete(true);
    }, remaining);

    return () => {
      if (timeoutId) {
        window.clearTimeout(timeoutId);
      }
    };
  }, [active, minVisibleMs, visible]);

  const handleComplete = useCallback(() => {
    setVisible(false);
    setComplete(false);
    startedAtRef.current = 0;
  }, []);

  return { visible, complete, handleComplete };
};

export const LoadingProgress: React.FC<LoadingProgressProps> = ({
  label,
  hint,
  variant = 'page',
  className = '',
  complete = false,
  onComplete,
}) => {
  const [progress, setProgress] = useState(10);
  const progressScale = Math.max(0.1, Math.min(1, progress / 100));
  const transitionDuration = `${complete ? FINAL_FILL_MS : 75}ms`;

  useEffect(() => {
    setProgress(10);
  }, [label, variant]);

  useEffect(() => {
    let animationFrameId = 0;
    let completionTimeoutId: number | undefined;
    const startAt = performance.now();

    const animate = () => {
      if (complete) {
        setProgress(100);
        completionTimeoutId = window.setTimeout(() => {
          onComplete?.();
        }, FINAL_FILL_MS + 40);
        return;
      }

      setProgress(getProgressFromElapsed(performance.now() - startAt));
      animationFrameId = window.requestAnimationFrame(animate);
    };

    animationFrameId = window.requestAnimationFrame(animate);

    return () => {
      window.cancelAnimationFrame(animationFrameId);
      if (completionTimeoutId) {
        window.clearTimeout(completionTimeoutId);
      }
    };
  }, [complete, label, onComplete, variant]);

  if (variant === 'button') {
    return (
      <div className={`inline-flex items-center gap-2 ${className}`.trim()}>
        <span className="text-[11px] font-semibold text-current/90">{label}</span>
        <div className="h-1 w-14 overflow-hidden rounded-full bg-current/20">
          <div
            className="h-full origin-left rounded-full bg-current transition-transform ease-out"
            style={{ transform: `scaleX(${progressScale})`, transitionDuration }}
          />
        </div>
        <span className="text-[10px] font-semibold tabular-nums text-current/80">
          {Math.round(progress)}%
        </span>
      </div>
    );
  }

  if (variant === 'inline') {
    return (
      <div className={`w-full ${className}`.trim()}>
        <div className="flex items-center justify-between gap-3 text-[11px] font-semibold text-white/90">
          <span>{label}</span>
          <span>{Math.round(progress)}%</span>
        </div>
        <div className="mt-1.5 h-1 w-full overflow-hidden rounded-full bg-white/20">
          <div
            className="h-full origin-left rounded-full bg-white transition-transform ease-out"
            style={{ transform: `scaleX(${progressScale})`, transitionDuration }}
          />
        </div>
      </div>
    );
  }

  return (
    <div className={`flex h-full items-center justify-center ${className}`.trim()}>
      <div className="w-full max-w-sm rounded-[28px] border border-slate-200 bg-white/88 px-6 py-6 shadow-sm backdrop-blur-sm">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-[11px] font-bold uppercase tracking-[0.24em] text-[#907CA1]">Chargement</p>
            <h3 className="mt-1.5 text-lg font-bold text-slate-900">{label}</h3>
            {hint && (
              <p className="mt-1.5 text-sm text-slate-500">{hint}</p>
            )}
          </div>
          <div className="pt-1 text-base font-bold text-slate-900 tabular-nums">
            {Math.round(progress)}%
          </div>
        </div>
        <div className="mt-4 h-1.5 overflow-hidden rounded-full bg-slate-100">
          <div
            className="h-full origin-left rounded-full bg-[#907CA1] transition-transform ease-out"
            style={{ transform: `scaleX(${progressScale})`, transitionDuration }}
          />
        </div>
      </div>
    </div>
  );
};

type SimpleLoaderProps = {
  label?: string;
  variant?: 'page' | 'inline' | 'button';
  className?: string;
};

export const SimpleLoader: React.FC<SimpleLoaderProps> = ({
  label,
  variant = 'page',
  className = '',
}) => {
  if (variant === 'button') {
    return (
      <span className={`inline-flex items-center gap-2 ${className}`.trim()}>
        <Loader2 size={16} className="animate-spin" />
        {label && <span>{label}</span>}
      </span>
    );
  }

  if (variant === 'inline') {
    return (
      <div className={`inline-flex items-center gap-3 text-slate-500 ${className}`.trim()}>
        <Loader2 size={18} className="animate-spin" />
        {label && <span className="text-sm font-medium">{label}</span>}
      </div>
    );
  }

  return (
    <div className={`flex h-full items-center justify-center ${className}`.trim()}>
      <div className="inline-flex items-center gap-3 rounded-full bg-white px-5 py-3 text-slate-600 shadow-sm border border-slate-200">
        <Loader2 size={18} className="animate-spin text-[#907CA1]" />
        {label && <span className="text-sm font-medium">{label}</span>}
      </div>
    </div>
  );
};

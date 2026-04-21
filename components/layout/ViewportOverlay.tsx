import React from 'react';
import { createPortal } from 'react-dom';

interface ViewportOverlayProps extends React.HTMLAttributes<HTMLDivElement> {
  children: React.ReactNode;
  className: string;
}

export const ViewportOverlay: React.FC<ViewportOverlayProps> = ({ children, className, ...rest }) => {
  if (typeof document === 'undefined') {
    return null;
  }

  return createPortal(
    <div className={className} {...rest}>
      {children}
    </div>,
    document.body,
  );
};

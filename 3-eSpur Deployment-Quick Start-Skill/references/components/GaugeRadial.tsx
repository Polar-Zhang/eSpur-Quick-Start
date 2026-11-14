"use client";

/** 通用 SVG 仪表盘（信息大屏）：240° 弧形表盘 + 中心大数字。
 *  zones 用于表盘底色分段（按数值语义着色），value 弧为主色覆盖。 */

export type GaugeZone = { from: number; to: number; color: string };

function polar(cx: number, cy: number, r: number, deg: number): [number, number] {
  // deg: 0 = 表盘正上方，顺时针为正
  const rad = (deg * Math.PI) / 180;
  return [cx + r * Math.sin(rad), cy - r * Math.cos(rad)];
}

function arcPath(cx: number, cy: number, r: number, a0: number, a1: number): string {
  const [x0, y0] = polar(cx, cy, r, a0);
  const [x1, y1] = polar(cx, cy, r, a1);
  const large = Math.abs(a1 - a0) > 180 ? 1 : 0;
  return `M ${x0.toFixed(2)} ${y0.toFixed(2)} A ${r} ${r} 0 ${large} 1 ${x1.toFixed(2)} ${y1.toFixed(2)}`;
}

export function GaugeRadial({
  value,
  min,
  max,
  label,
  unit,
  digits = 2,
  size = 210,
  accent = "var(--accent)",
  zones = [],
}: {
  value: number;
  min: number;
  max: number;
  label: string;
  unit?: string;
  digits?: number;
  size?: number;
  accent?: string;
  zones?: GaugeZone[];
}) {
  const cx = size / 2;
  const cy = size / 2 + 6;
  const r = size / 2 - 18;
  const A0 = -120;
  const SWEEP = 240;
  const clamped = Math.min(max, Math.max(min, value));
  const frac = max > min ? (clamped - min) / (max - min) : 0;

  const zoneArcs = zones.map((zone, index) => {
    const f0 = Math.min(1, Math.max(0, (zone.from - min) / (max - min)));
    const f1 = Math.min(1, Math.max(0, (zone.to - min) / (max - min)));
    if (f1 <= f0) return null;
    return (
      <path
        key={index}
        d={arcPath(cx, cy, r, A0 + SWEEP * f0, A0 + SWEEP * f1)}
        fill="none"
        stroke={zone.color}
        strokeWidth={14}
        strokeLinecap="butt"
        opacity={0.28}
      />
    );
  });

  return (
    <svg width="100%" viewBox={`0 0 ${size} ${size + 8}`} role="img" aria-label={`${label}: ${value}`}>
      {zoneArcs}
      <path d={arcPath(cx, cy, r, A0, A0 + SWEEP)} fill="none" stroke="var(--line)" strokeWidth={14} strokeLinecap="round" opacity={0.5} />
      {frac > 0.001 ? (
        <path
          d={arcPath(cx, cy, r, A0, A0 + SWEEP * frac)}
          fill="none"
          stroke={accent}
          strokeWidth={14}
          strokeLinecap="round"
        />
      ) : null}
      <text x={cx} y={cy - 2} textAnchor="middle" fontSize={size / 5.4} fontWeight={600} fill="var(--text)">
        {value.toFixed(digits)}
      </text>
      <text x={cx} y={cy + 22} textAnchor="middle" fontSize={12} fill="var(--muted)">
        {unit || ""}
      </text>
      <text x={cx} y={cy + r + 18} textAnchor="middle" fontSize={12} fill="var(--muted)">
        {label}
      </text>
    </svg>
  );
}

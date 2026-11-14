"use client";

import { ReactNode } from "react";

/** 信息大屏中央：等距（isometric）3D 机房 SVG。
 *  每台服务器 = 一个机柜（三面体），顶面 4 个 PSU 口组方块（开=发光/关=暗），
 *  按机房（站点）分组铺地台。纯 SVG，零外部依赖，随数据量伸缩。 */

type IsoServer = {
  name: string;
  external_id: number;
  outlets: string;
  psu_state: string | null;
  power_w: number | null;
  online: boolean;
};
export type IsoSite = { name: string; online: boolean; servers: IsoServer[] };

const CX = Math.cos(Math.PI / 6); // 0.866
const SY = 0.5;

function iso(x: number, y: number, z: number): [number, number] {
  return [(x - y) * CX, (x + y) * SY - z];
}

function poly(points: Array<[number, number]>, fill: string, stroke = "none", opacity = 1, key?: string) {
  return (
    <polygon
      key={key}
      points={points.map((p) => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ")}
      fill={fill}
      stroke={stroke}
      strokeWidth={stroke === "none" ? 0 : 0.6}
      opacity={opacity}
    />
  );
}

function isoBox(
  x: number, y: number, w: number, d: number, h: number,
  key: string,
  topFill: string, rightFill: string, frontFill: string,
) {
  const A = iso(x, y, h);
  const B = iso(x + w, y, h);
  const C = iso(x + w, y + d, h);
  const D = iso(x, y + d, h);
  const B0 = iso(x + w, y, 0);
  const C0 = iso(x + w, y + d, 0);
  const D0 = iso(x, y + d, 0);
  return (
    <g key={key}>
      {poly([D, C, C0, D0], frontFill)}
      {poly([B, C, C0, B0], rightFill)}
      {poly([A, B, C, D], topFill)}
    </g>
  );
}

export function MachineRoomIso({ sites, height = 340 }: { sites: IsoSite[]; height?: number }) {
  const RACK_W = 74;
  const RACK_D = 50;
  const RACK_H = 46;
  const GAP = 34;
  const SITE_GAP = 46;

  // 布局：机房沿 x 展开机房地台，服务器机柜在机房内地台排开
  type placed = {
    site: IsoSite; x: number; y: number;
    racks: Array<{ server: IsoServer; x: number; y: number }>;
    floorX0: number; floorX1: number;
  };
  const placed: placed[] = [];
  let cursorX = 30;
  for (const site of sites) {
    const racks = site.servers.map((server, index) => ({
      server,
      x: cursorX + index * (RACK_W + GAP),
      y: 70,
    }));
    const floorX0 = cursorX - 22;
    const floorX1 = cursorX + Math.max(site.servers.length, 1) * (RACK_W + GAP) - GAP + RACK_W + 22;
    placed.push({ site, x: cursorX, y: 70, racks, floorX0, floorX1 });
    cursorX = floorX1 + SITE_GAP;
  }

  // 视图范围（含文字余量）
  let minX = 0; let maxX = 0; let minY = 1e9; let maxY = -1e9;
  for (const p of placed) {
    for (const [sx, sy] of [
      iso(p.floorX0, 20, 0), iso(p.floorX1, 20, 0),
      iso(p.floorX1, p.y + RACK_D + 46, 0), iso(p.floorX0, p.y + RACK_D + 46, 0),
      iso(p.floorX0, p.y - 40, RACK_H + 40), iso(p.floorX1, p.y - 40, RACK_H + 40),
    ]) {
      minX = Math.min(minX, sx); maxX = Math.max(maxX, sx);
      minY = Math.min(minY, sy); maxY = Math.max(maxY, sy);
    }
  }
  const pad = 24;
  const vb = `${(minX - pad).toFixed(0)} ${(minY - pad).toFixed(0)} ${(maxX - minX + pad * 2).toFixed(0)} ${(maxY - minY + pad * 2 + 10).toFixed(0)}`;

  // 画家算法：先地台（按机房），再机柜（整体按 x+y 从小到大）
  const floorEls = placed.map((p, index) => {
    const c1 = iso(p.floorX0, 30, 0);
    const c2 = iso(p.floorX1, 30, 0);
    const c3 = iso(p.floorX1, p.y + RACK_D + 34, 0);
    const c4 = iso(p.floorX0, p.y + RACK_D + 34, 0);
    const mid = iso((p.floorX0 + p.floorX1) / 2, p.y + RACK_D + 20, 0);
    return (
      <g key={`floor-${index}`}>
        {poly([c1, c2, c3, c4], "var(--surface-muted)", "var(--line)", 1, `f-${index}`)}
        <text x={mid[0]} y={mid[1] + 4} textAnchor="middle" fontSize={12} fill="var(--muted)">
          {p.site.name}
        </text>
      </g>
    );
  });

  const rackEls: ReactNode[] = [];
  for (const p of placed) {
    for (const rack of p.racks) {
      const s = rack.server;
      const short = s.name.includes("_") ? s.name.split("_").pop() || "" : s.name;
      const state = s.psu_state || "0000";
      const onCount = (state.match(/1/g) || []).length;
      // 机柜三面（暗色调，主站变量）
      const top = "var(--surface-strong)";
      const right = "var(--surface-muted)";
      const front = "var(--line)";
      rackEls.push(
        <g key={`rack-${rack.server.external_id}`}>
          {isoBox(rack.x, rack.y, RACK_W, RACK_D, RACK_H, `b-${rack.server.external_id}`, top, right, front)}
          {/* 顶面 PSU 口组方块（独立于机柜的小立方体） */}
          {state.split("").map((ch, index) => {
            const cw = 13;
            const cx = rack.x + 10 + index * (cw + 4);
            const cy = rack.y + 8;
            const ch_ = 9;
            const on = ch === "1";
            const glow = on ? "url(#psu-glow)" : undefined;
            return (
              <g key={index} filter={glow}>
                {isoBox(cx, cy, cw, cw * 0.7, ch_, `c-${rack.server.external_id}-${index}`,
                  on ? "var(--accent)" : "var(--line)",
                  on ? "rgba(42,111,151,0.95)" : "rgba(148,163,184,0.7)",
                  on ? "rgba(21,58,80,0.95)" : "rgba(100,116,139,0.7)")}
              </g>
            );
          })}
          {/* 功率标签（浮动于机柜上方） */}
          <text
            x={iso(rack.x + RACK_W / 2, rack.y + RACK_D / 2, RACK_H + 34)[0]}
            y={iso(rack.x + RACK_W / 2, rack.y + RACK_D / 2, RACK_H + 34)[1]}
            textAnchor="middle" fontSize={15} fontWeight={600} fill="var(--text)"
          >
            {s.power_w !== null ? `${s.power_w.toFixed(1)} W` : "--"}
          </text>
          {/* 服务器短标签（口组）+ 在线灯，置于机柜前缘 */}
          <text
            x={iso(rack.x + RACK_W / 2, rack.y + RACK_D + 6, 0)[0]}
            y={iso(rack.x + RACK_W / 2, rack.y + RACK_D + 6, 0)[1] + 12}
            textAnchor="middle" fontSize={11} fill="var(--muted)"
          >
            {short} · {onCount}/{state.length} 开
          </text>
        </g>,
      );
    }
  }

  return (
    <svg width="100%" height={height} viewBox={vb} role="img" aria-label="机房 3D 总览">
      <defs>
        <filter id="psu-glow" x="-40%" y="-40%" width="180%" height="180%">
          <feDropShadow dx="0" dy="0" stdDeviation="2.4" floodColor="#2a6f97" floodOpacity="0.9" />
        </filter>
      </defs>
      {floorEls}
      {rackEls}
    </svg>
  );
}

import { useMemo, useState } from 'react'
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Copy, RotateCcw } from 'lucide-react'

function shortAgo(dateStr: string): string {
  const diff = Date.now() - new Date(dateStr + 'Z').getTime()
  const s = Math.floor(diff / 1000)
  if (s < 60) return `${s}s ago`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ago`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ago`
  const d = Math.floor(h / 24)
  if (d < 30) return `${d}d ago`
  const mo = Math.floor(d / 30)
  return `${mo}mo ago`
}
import { NodeStatus } from '../types'
import StatusBadge from './StatusBadge'
import api from '../api/client'
import { copyToClipboard } from '../utils/clipboard'

interface UpdateTarget {
  node_id: string
  version: string | null
}

interface EditingNote {
  node_id: string
  value: string
}

interface Props {
  nodes: NodeStatus[]
  selectedIds: Set<string>
  onSelectionChange: (ids: Set<string>) => void
  sorting: SortingState
  onSortingChange: (s: SortingState) => void
  onTagClick?: (tagId: number) => void
}

const col = createColumnHelper<NodeStatus>()

const STATUS_ORDER = ['Online', 'NoInternet', 'Unbound', 'proxy_expired', 'Offline', null]

const toFlagEmoji = (cc: string) =>
  cc.toUpperCase().replace(/./g, c => String.fromCodePoint(c.charCodeAt(0) + 127397))

export default function NodeTable({ nodes, selectedIds, onSelectionChange, sorting, onSortingChange, onTagClick }: Props) {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [updateTarget, setUpdateTarget] = useState<UpdateTarget | null>(null)
  const [editingNote, setEditingNote] = useState<EditingNote | null>(null)

  const saveNote = useMutation({
    mutationFn: ({ node_id, notes }: { node_id: string; notes: string }) =>
      api.put(`/dashboard/nodes/${encodeURIComponent(node_id)}/notes`, { notes }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['nodes'] })
      setEditingNote(null)
    },
  })

  const sendUpdate = useMutation({
    mutationFn: (node_id: string) =>
      api.post('/dashboard/commands', { node_id, action: 'update_script' }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['commands'] })
      setUpdateTarget(null)
    },
  })

  const allVisibleIds = nodes.map(n => n.node_id)
  const allSelected = allVisibleIds.length > 0 && allVisibleIds.every(id => selectedIds.has(id))
  const someSelected = allVisibleIds.some(id => selectedIds.has(id))

  const toggleAll = () => {
    if (allSelected) {
      const next = new Set(selectedIds)
      allVisibleIds.forEach(id => next.delete(id))
      onSelectionChange(next)
    } else {
      const next = new Set(selectedIds)
      allVisibleIds.forEach(id => next.add(id))
      onSelectionChange(next)
    }
  }

  const toggleOne = (id: string) => {
    const next = new Set(selectedIds)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    onSelectionChange(next)
  }

  const columns = useMemo(
    () => [
      col.display({
        id: 'select',
        header: () => (
          <input
            type="checkbox"
            checked={allSelected}
            ref={el => { if (el) el.indeterminate = someSelected && !allSelected }}
            onChange={toggleAll}
            className="rounded border-gray-300 text-blue-600 cursor-pointer"
          />
        ),
        cell: info => (
          <input
            type="checkbox"
            checked={selectedIds.has(info.row.original.node_id)}
            onChange={() => toggleOne(info.row.original.node_id)}
            onClick={e => e.stopPropagation()}
            className="rounded border-gray-300 text-blue-600 cursor-pointer"
          />
        ),
      }),
      col.accessor(row => ({ id: row.node_id, needs_renew: row.needs_renew, country_code: row.country_code }), {
        id: 'node_id',
        header: 'Hostname',
        sortingFn: (a, b) => a.original.node_id.localeCompare(b.original.node_id),
        cell: info => {
          const { id, needs_renew, country_code } = info.getValue()
          return (
            <span className="flex items-center gap-1.5 group/host">
              <a
                href={`/nodes/${encodeURIComponent(id)}`}
                onClick={e => { e.preventDefault(); navigate(`/nodes/${encodeURIComponent(id)}`) }}
                className="font-mono text-sm font-medium text-blue-600 hover:underline text-left"
              >
                {id}
              </a>
              {country_code && (
                <span title={country_code} className="text-base leading-none shrink-0">
                  {toFlagEmoji(country_code)}
                </span>
              )}
              {needs_renew && (
                <span title="Cần renew: reward=0 và uptime=0" className="text-orange-500 shrink-0">
                  <RotateCcw size={11} />
                </span>
              )}
              <button
                onClick={e => { e.stopPropagation(); copyToClipboard(id) }}
                title="Copy hostname"
                className="opacity-0 group-hover/host:opacity-100 transition-opacity text-gray-400 hover:text-blue-500 shrink-0"
              >
                <Copy size={12} />
              </button>
            </span>
          )
        },
      }),
      col.accessor('serial', {
        header: 'Serial',
        cell: info => {
          const v = info.getValue()
          if (!v) return <span className="text-sm text-gray-400">—</span>
          return (
            <span className="flex items-center gap-1 group/serial">
              <span className="font-mono text-sm text-gray-700">{v}</span>
              <button
                onClick={e => { e.stopPropagation(); copyToClipboard(v) }}
                title="Copy serial"
                className="opacity-0 group-hover/serial:opacity-100 transition-opacity text-gray-400 hover:text-blue-500 shrink-0"
              >
                <Copy size={12} />
              </button>
            </span>
          )
        },
      }),
      col.accessor(row => ({ s: row.aro_status, stale: row.is_stale }), {
        id: 'status',
        header: 'Status',
        cell: info => <StatusBadge status={info.getValue().s} isStale={info.getValue().stale} />,
        sortingFn: (a, b) =>
          STATUS_ORDER.indexOf(a.original.aro_status) - STATUS_ORDER.indexOf(b.original.aro_status),
      }),
      col.accessor('account', {
        header: 'Account',
        cell: info => <span className="text-sm text-gray-600 truncate max-w-[160px] block">{info.getValue() ?? '—'}</span>,
      }),
      col.accessor('total_score', {
        header: 'Tổng điểm',
        cell: info => {
          const v = info.getValue()
          return <span className="text-sm font-mono">{v != null ? v.toLocaleString() : '—'}</span>
        },
      }),
      col.accessor('avg_score', {
        header: 'TB/ngày',
        cell: info => {
          const v = info.getValue()
          return <span className="text-sm font-mono">{v != null ? v.toLocaleString() : '—'}</span>
        },
      }),
      col.accessor('reward_yesterday', {
        header: () => <span className="leading-tight normal-case tracking-normal">Điểm<br />hôm qua</span>,
        cell: info => {
          const v = info.getValue()
          return <span className="text-sm font-mono">{v != null ? v.toLocaleString() : '—'}</span>
        },
      }),
      col.accessor('uptime_ratio', {
        header: 'Uptime',
        cell: info => {
          const v = info.getValue()
          if (v == null) return <span className="text-gray-300">—</span>
          const pct = v * 100
          const cls = pct >= 95 ? 'text-green-600' : pct >= 80 ? 'text-yellow-600' : 'text-red-600'
          return <span className={`text-sm font-mono ${cls}`}>{pct.toFixed(1)}%</span>
        },
      }),
      col.accessor('proxy_ok', {
        header: 'Proxy',
        cell: info => {
          const v = info.getValue()
          if (v == null) return <span className="text-gray-300">—</span>
          return v
            ? <span className="text-green-600 text-sm">✓ OK</span>
            : <span className="text-red-600 text-sm">✗ Down</span>
        },
      }),
      col.accessor('public_ip', {
        header: 'Exit IP',
        cell: info => <span className="text-xs font-mono text-gray-500">{info.getValue() || 'N/A'}</span>,
      }),
      col.accessor('last_seen', {
        header: 'Last Seen',
        cell: info => {
          const v = info.getValue()
          if (!v) return <span className="text-gray-300 text-sm">Never</span>
          return (
            <span className="text-sm text-gray-500 font-mono" title={new Date(v + 'Z').toLocaleString('vi-VN')}>
              {shortAgo(v)}
            </span>
          )
        },
      }),
      col.accessor(row => ({ version: row.script_version, node_id: row.node_id }), {
        id: 'script_version',
        header: 'Ver',
        cell: info => {
          const { version, node_id } = info.getValue()
          if (!version) return <span className="text-gray-300 text-xs">—</span>
          return (
            <button
              onClick={e => { e.stopPropagation(); setUpdateTarget({ node_id, version }) }}
              title="Click để cập nhật script"
              className="text-xs font-mono text-indigo-500 hover:text-indigo-700 hover:underline cursor-pointer"
            >
              {version}
            </button>
          )
        },
        sortingFn: (a, b) => {
          const parseVer = (v: string | null) =>
            (v ?? '').split('.').map(n => parseInt(n, 10) || 0)
          const pa = parseVer(a.original.script_version)
          const pb = parseVer(b.original.script_version)
          for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
            const diff = (pa[i] ?? 0) - (pb[i] ?? 0)
            if (diff !== 0) return diff
          }
          return 0
        },
      }),
      col.accessor('renew_count', {
        header: 'Renew',
        cell: info => {
          const v = info.getValue() ?? 0
          if (v === 0) return <span className="text-gray-200 text-xs">—</span>
          return (
            <span className={`inline-flex items-center gap-0.5 px-1.5 py-0.5 rounded-full text-xs font-bold ${
              v >= 5 ? 'bg-red-100 text-red-700' :
              v >= 3 ? 'bg-orange-100 text-orange-700' :
              'bg-blue-100 text-blue-700'
            }`}>
              <RotateCcw size={9} />
              {v}
            </span>
          )
        },
      }),
      col.accessor('tags', {
        id: 'tags',
        header: 'Tags',
        enableSorting: false,
        cell: info => {
          const tags = info.getValue() ?? []
          if (tags.length === 0) return <span className="text-gray-300 text-xs">—</span>
          const visible = tags.slice(0, 3)
          const rest = tags.length - visible.length
          return (
            <div className="flex items-center gap-1 flex-wrap">
              {visible.map((t: { id: number; name: string; color: string }) => (
                <button key={t.id}
                  onClick={e => { e.stopPropagation(); onTagClick?.(t.id) }}
                  title={`Lọc theo tag "${t.name}"`}
                  className="inline-flex items-center px-1.5 py-0.5 rounded-full text-xs font-medium text-white hover:opacity-80 transition-opacity"
                  style={{ backgroundColor: t.color }}>
                  {t.name}
                </button>
              ))}
              {rest > 0 && <span className="text-xs text-gray-400">+{rest}</span>}
            </div>
          )
        },
      }),
      col.accessor('notes', {
        header: 'Ghi chú',
        cell: info => {
          const node_id = info.row.original.node_id
          const current = info.getValue()
          if (editingNote?.node_id === node_id) {
            return (
              <input autoFocus value={editingNote.value}
                onChange={e => setEditingNote({ node_id, value: e.target.value })}
                onBlur={() => saveNote.mutate({ node_id, notes: editingNote.value })}
                onKeyDown={e => {
                  if (e.key === 'Enter') saveNote.mutate({ node_id, notes: editingNote.value })
                  if (e.key === 'Escape') setEditingNote(null)
                }}
                onClick={e => e.stopPropagation()}
                className="text-sm border border-blue-400 rounded px-1.5 py-0.5 w-40 outline-none focus:ring-1 focus:ring-blue-400"
              />
            )
          }
          return (
            <span onClick={e => { e.stopPropagation(); setEditingNote({ node_id, value: current ?? '' }) }}
              title="Click để chỉnh sửa"
              className="text-sm text-gray-600 truncate max-w-[160px] block cursor-text hover:bg-gray-100 rounded px-1 -mx-1 min-w-[80px] min-h-[20px]">
              {current || <span className="text-gray-300">—</span>}
            </span>
          )
        },
      }),
    ],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [navigate, selectedIds, allSelected, someSelected, editingNote, onTagClick],
  )

  const table = useReactTable({
    data: nodes,
    columns,
    state: { sorting },
    onSortingChange: onSortingChange as (updater: unknown) => void,
    manualSorting: true,
    getCoreRowModel: getCoreRowModel(),
  })

  return (
    <>
      {updateTarget && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
          <div className="bg-white rounded-xl shadow-xl p-6 w-full max-w-sm mx-4">
            <h3 className="text-base font-semibold text-gray-800 mb-1">Cập nhật Script</h3>
            <p className="text-sm text-gray-500 mb-4">
              Node: <span className="font-mono font-medium text-gray-800">{updateTarget.node_id}</span>
              <br />
              Version hiện tại: <span className="font-mono text-indigo-600">{updateTarget.version}</span>
            </p>
            <p className="text-sm text-gray-600 mb-5">
              Script mới nhất sẽ được tải từ GitHub và watchdog sẽ tự restart. ARO không bị gián đoạn.
            </p>
            <div className="flex gap-3 justify-end">
              <button
                onClick={() => setUpdateTarget(null)}
                className="px-4 py-2 text-sm text-gray-700 bg-gray-100 rounded-lg hover:bg-gray-200"
              >
                Huỷ
              </button>
              <button
                onClick={() => sendUpdate.mutate(updateTarget.node_id)}
                disabled={sendUpdate.isPending}
                className="px-4 py-2 text-sm text-white bg-indigo-600 rounded-lg hover:bg-indigo-700 disabled:opacity-50"
              >
                {sendUpdate.isPending ? 'Đang gửi...' : 'Xác nhận cập nhật'}
              </button>
            </div>
          </div>
        </div>
      )}

      <div className="overflow-x-auto rounded-lg shadow">
        <table className="min-w-full bg-white divide-y divide-gray-200">
          <thead className="bg-gray-50 sticky top-14 z-10">
            {table.getHeaderGroups().map(hg => (
              <tr key={hg.id}>
                {hg.headers.map(h => (
                  <th
                    key={h.id}
                    onClick={h.id === 'select' ? undefined : h.column.getToggleSortingHandler()}
                    className={`px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider ${h.id === 'reward_yesterday' ? 'whitespace-normal' : 'whitespace-nowrap'} ${h.id !== 'select' ? 'cursor-pointer select-none' : ''}`}
                  >
                    {flexRender(h.column.columnDef.header, h.getContext())}
                    {h.id !== 'select' && ({ asc: ' ↑', desc: ' ↓' }[h.column.getIsSorted() as string] ?? '')}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody className="divide-y divide-gray-100">
            {table.getRowModel().rows.map(row => (
              <tr
                key={row.id}
                className={`hover:bg-gray-50 transition-colors ${selectedIds.has(row.original.node_id) ? 'bg-blue-50' : ''}`}
              >
                {row.getVisibleCells().map(cell => (
                  <td key={cell.id} className="px-3 py-2.5 whitespace-nowrap">
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
        {nodes.length === 0 && (
          <div className="text-center py-12 text-gray-400 bg-white">No nodes found</div>
        )}
      </div>
    </>
  )
}

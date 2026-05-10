import { useMemo, useState } from 'react'
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table'
import { useNavigate } from 'react-router-dom'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { formatDistanceToNow } from 'date-fns'
import { NodeStatus } from '../types'
import StatusBadge from './StatusBadge'
import api from '../api/client'
import { copyToClipboard } from '../utils/clipboard'

interface UpdateTarget {
  node_id: string
  version: string | null
}

interface Props {
  nodes: NodeStatus[]
  selectedIds: Set<string>
  onSelectionChange: (ids: Set<string>) => void
}

const col = createColumnHelper<NodeStatus>()

const STATUS_ORDER = ['Online', 'NoInternet', 'Unbound', 'Offline', null]

export default function NodeTable({ nodes, selectedIds, onSelectionChange }: Props) {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const [sorting, setSorting] = useState<SortingState>([{ id: 'node_id', desc: false }])
  const [updateTarget, setUpdateTarget] = useState<UpdateTarget | null>(null)

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
      col.accessor('node_id', {
        header: 'Hostname',
        cell: info => (
          <button
            onClick={() => navigate(`/nodes/${encodeURIComponent(info.getValue())}`)}
            className="font-mono text-sm font-medium text-blue-600 hover:underline text-left"
          >
            {info.getValue()}
          </button>
        ),
      }),
      col.accessor('serial', {
        header: 'Serial',
        cell: info => {
          const v = info.getValue()
          if (!v) return <span className="text-sm text-gray-400">—</span>
          return (
            <button
              onClick={() => copyToClipboard(v)}
              title="Click to copy"
              className="font-mono text-sm text-gray-700 hover:text-blue-600 hover:underline cursor-copy"
            >
              {v}
            </button>
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
      col.accessor('reward_yesterday', {
        header: 'Điểm (pts)',
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
        cell: info => <span className="text-xs font-mono text-gray-500">{info.getValue() ?? '—'}</span>,
      }),
      col.accessor('last_seen', {
        header: 'Last Seen',
        cell: info => {
          const v = info.getValue()
          if (!v) return <span className="text-gray-300 text-sm">Never</span>
          return (
            <span className="text-sm text-gray-500">
              {formatDistanceToNow(new Date(v + 'Z'), { addSuffix: true })}
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
      }),
    ],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [navigate, selectedIds, allSelected, someSelected],
  )

  const table = useReactTable({
    data: nodes,
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
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
          <thead className="bg-gray-50">
            {table.getHeaderGroups().map(hg => (
              <tr key={hg.id}>
                {hg.headers.map(h => (
                  <th
                    key={h.id}
                    onClick={h.id === 'select' ? undefined : h.column.getToggleSortingHandler()}
                    className={`px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider whitespace-nowrap ${h.id !== 'select' ? 'cursor-pointer select-none' : ''}`}
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

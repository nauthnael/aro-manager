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
import { formatDistanceToNow } from 'date-fns'
import { NodeStatus } from '../types'
import StatusBadge from './StatusBadge'

const col = createColumnHelper<NodeStatus>()

const STATUS_ORDER = ['Online', 'NoInternet', 'Unbound', 'Offline', null]

export default function NodeTable({ nodes }: { nodes: NodeStatus[] }) {
  const navigate = useNavigate()
  const [sorting, setSorting] = useState<SortingState>([])

  const columns = useMemo(
    () => [
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
      col.accessor('reward_today', {
        header: 'Today (pts)',
        cell: info => {
          const v = info.getValue()
          return <span className="text-sm font-mono">{v != null ? v.toLocaleString() : '—'}</span>
        },
      }),
      col.accessor('reward_yesterday', {
        header: 'Yesterday',
        cell: info => {
          const v = info.getValue()
          return <span className="text-sm font-mono text-gray-400">{v != null ? v.toLocaleString() : '—'}</span>
        },
      }),
      col.accessor('uptime_ratio', {
        header: 'Uptime',
        cell: info => {
          const v = info.getValue()
          if (v == null) return <span className="text-gray-300">—</span>
          const cls = v >= 95 ? 'text-green-600' : v >= 80 ? 'text-yellow-600' : 'text-red-600'
          return <span className={`text-sm font-mono ${cls}`}>{v.toFixed(1)}%</span>
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
      col.accessor('script_version', {
        header: 'Ver',
        cell: info => <span className="text-xs text-gray-400 font-mono">{info.getValue() ?? '—'}</span>,
      }),
    ],
    [navigate],
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
    <div className="overflow-x-auto rounded-lg shadow">
      <table className="min-w-full bg-white divide-y divide-gray-200">
        <thead className="bg-gray-50">
          {table.getHeaderGroups().map(hg => (
            <tr key={hg.id}>
              {hg.headers.map(h => (
                <th
                  key={h.id}
                  onClick={h.column.getToggleSortingHandler()}
                  className="px-3 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer select-none whitespace-nowrap"
                >
                  {flexRender(h.column.columnDef.header, h.getContext())}
                  {{ asc: ' ↑', desc: ' ↓' }[h.column.getIsSorted() as string] ?? ''}
                </th>
              ))}
            </tr>
          ))}
        </thead>
        <tbody className="divide-y divide-gray-100">
          {table.getRowModel().rows.map(row => (
            <tr key={row.id} className="hover:bg-gray-50 transition-colors">
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
  )
}

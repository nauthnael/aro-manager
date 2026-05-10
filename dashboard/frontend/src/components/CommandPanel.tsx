import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { formatDistanceToNow } from 'date-fns'
import { Command } from '../types'
import api from '../api/client'

const ACTIONS = [
  { id: 'restart_aro',      label: 'Restart ARO',      cls: 'bg-blue-600 hover:bg-blue-700',     confirm: true  },
  { id: 'restart_watchdog', label: 'Restart Watchdog', cls: 'bg-orange-600 hover:bg-orange-700', confirm: true  },
  { id: 'debug_aro',        label: 'Debug ARO',        cls: 'bg-gray-600 hover:bg-gray-700',     confirm: false },
  { id: 'reboot_vps',       label: 'Reboot VPS',       cls: 'bg-red-600 hover:bg-red-700',       confirm: true  },
  { id: 'update_script',    label: 'Cập nhật Script',  cls: 'bg-indigo-600 hover:bg-indigo-700', confirm: true  },
]

const STATUS_CLS: Record<string, string> = {
  pending:   'bg-yellow-100 text-yellow-800',
  acked:     'bg-blue-100 text-blue-800',
  completed: 'bg-green-100 text-green-800',
  failed:    'bg-red-100 text-red-800',
}

export default function CommandPanel({ nodeId }: { nodeId: string }) {
  const qc = useQueryClient()
  const [expandedId, setExpandedId] = useState<number | null>(null)

  const { data: commands = [] } = useQuery<Command[]>({
    queryKey: ['commands', nodeId],
    queryFn: () =>
      api.get(`/dashboard/commands?node_id=${encodeURIComponent(nodeId)}&limit=20`).then(r => r.data),
    refetchInterval: 5_000,
  })

  const send = useMutation({
    mutationFn: (action: string) => api.post('/dashboard/commands', { node_id: nodeId, action }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['commands', nodeId] }),
  })

  const cancel = useMutation({
    mutationFn: (id: number) => api.delete(`/dashboard/commands/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['commands', nodeId] }),
  })

  const handleClick = (action: typeof ACTIONS[0]) => {
    if (action.confirm && !confirm(`Gửi lệnh "${action.label}" đến node ${nodeId}?`)) return
    send.mutate(action.id)
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap gap-2">
        {ACTIONS.map(a => (
          <button
            key={a.id}
            onClick={() => handleClick(a)}
            disabled={send.isPending}
            className={`px-4 py-2 text-sm font-medium text-white rounded-lg ${a.cls} disabled:opacity-50 transition-colors`}
          >
            {a.label}
          </button>
        ))}
      </div>

      {commands.length > 0 && (
        <div className="space-y-2">
          <p className="text-xs font-medium text-gray-500 uppercase tracking-wide">Command History</p>
          {commands.map(cmd => (
            <div key={cmd.id} className="bg-gray-50 border border-gray-100 rounded-lg p-3 text-sm">
              <div className="flex items-center justify-between gap-2">
                <div className="flex items-center gap-2 min-w-0">
                  <span className="font-mono font-medium text-gray-800">{cmd.action}</span>
                  <span className={`shrink-0 px-2 py-0.5 rounded-full text-xs font-medium ${STATUS_CLS[cmd.status] ?? 'bg-gray-100 text-gray-600'}`}>
                    {cmd.status}
                  </span>
                  {cmd.created_by && <span className="text-gray-400 text-xs">by {cmd.created_by}</span>}
                </div>
                <div className="flex items-center gap-2 shrink-0">
                  <span className="text-gray-400 text-xs">
                    {formatDistanceToNow(new Date(cmd.created_at + 'Z'), { addSuffix: true })}
                  </span>
                  {cmd.status === 'pending' && (
                    <button
                      onClick={() => cancel.mutate(cmd.id)}
                      className="text-xs text-red-500 hover:text-red-700"
                    >
                      Cancel
                    </button>
                  )}
                </div>
              </div>

              {cmd.result && (
                <div className="mt-2">
                  <button
                    onClick={() => setExpandedId(expandedId === cmd.id ? null : cmd.id)}
                    className="text-xs text-blue-600 hover:underline"
                  >
                    {expandedId === cmd.id ? 'Hide output' : 'Show output'}
                  </button>
                  {expandedId === cmd.id && (
                    <pre className="mt-2 text-xs bg-gray-900 text-green-400 p-3 rounded-lg overflow-x-auto max-h-72 whitespace-pre-wrap">
                      {cmd.result}
                    </pre>
                  )}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

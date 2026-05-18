import { useNavigate } from 'react-router-dom'

/**
 * Returns a goBack function that navigates to the previous history entry.
 * Falls back to `fallback` (default '/') when there is no prior history
 * (e.g. the user opened the page directly via bookmark or new tab).
 */
export function useGoBack(fallback = '/') {
  const navigate = useNavigate()
  return () => {
    if (window.history.length > 1) navigate(-1)
    else navigate(fallback)
  }
}

/**
 * usePermissions hook
 *
 * Convenience re-export so components can import from the hooks folder
 * (consistent with the rest of the codebase) rather than from contexts/.
 *
 * @example
 *   import { usePermissions } from '../hooks/usePermissions';
 *   const { can } = usePermissions();
 */
export { usePermissions } from '../contexts/PermissionContext';

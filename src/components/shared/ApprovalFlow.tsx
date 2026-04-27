import { Fragment } from 'react';
import type { ExpenseStatus } from '../../types';

const NODES = [
  { key: 'submitted', label: 'Submitted' },
  { key: 'manager',   label: 'Manager'   },
  { key: 'hr',        label: 'HR'        },
  { key: 'finance',   label: 'Finance'   },
];

function getStepState(status: ExpenseStatus, idx: number): 'done' | 'active' | 'pending' {
  let doneCount = 0;
  let activeIdx = -1;
  if (status === 'submitted') { doneCount = 1; activeIdx = 1; }
  if (status === 'approved')  { doneCount = 4; }

  if (idx < doneCount) return 'done';
  if (idx === activeIdx) return 'active';
  return 'pending';
}

interface Props { status: ExpenseStatus; }

export default function ApprovalFlow({ status }: Props) {
  return (
    <div className="exp-flow-steps">
      {NODES.map((node, i) => {
        const state = getStepState(status, i);
        const icon = state === 'done'   ? 'fa-circle-check'
                   : state === 'active' ? 'fa-circle-dot'
                   :                      'fa-circle';
        // connector is "done" if both this step and the next are done
        const connectorDone = i < NODES.length - 1 && getStepState(status, i + 1) !== 'pending'
          ? ' exp-flow-connector--done' : '';
        return (
          <Fragment key={node.key}>
            <div className={`exp-flow-step exp-flow-step--${state}`}>
              <i className={`fa-solid ${icon}`} />
              <span>{node.label}</span>
            </div>
            {i < NODES.length - 1 && (
              <div className={`exp-flow-connector${connectorDone}`} />
            )}
          </Fragment>
        );
      })}
    </div>
  );
}

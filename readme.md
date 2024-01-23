# BitQueue

## Commands

- `1`
  - Enqueue 1
- `0`
  - Enqueue 0
- `>`
  - Call the function with the name that follows
- `<`
  - Return from current function
- `^`
  - Return from current function and then jump to the start of the calling function
- `*`
  - Return from current function and the calling function
- `"`
  - Call the currently running function
- `:`
  - Define a function with the name that follows and the body being the next command or block
- `'`
  - Create and call an anonymous function with the body being the next command or block
- `?`
  - Dequeue a bit, if it is 0, then skip the next command or block
- `(`
  - Start a block
- `)`
  - End the block starting with the matching `(`
- `,`
  - Enqueue the next 8 bits of input, if no input is available, then nothing is enqueued
- `.`
  - Dequeue 8 bits and send them to the output
- `#`
 	- Print the queue state as a series of 1s and 0s followed by a newline
- `;`
  - Start a comment that lasts until the end of the line 

## Notes
- Named functions may only be created at the top level (not within a function,
  conditional or block).

- Function names are of the form `/[A-Za-z_][A-Za-z0-9_]*/` and may not
  conflict.

- Calling a non-existent function is not allowed.

- When the end of a function is reached, then the function implicitly returns.

- When a command or block is expected then it must be given.

- Returning when not inside a function halts.

- Dequeuing from an empty queue halts.

- Reaching the end of the file halts.

- If a single command is given when a command or block is expected, then any
  arguments it takes are included as well.

- `.` dequeues and outputs bits in the order they were given. For example,
  `01000001`. will output A (assuming the output is displayed as ASCII).

- `,` enqueues the inputted bits such that the high-order bit is enqueued
  first. For example, `,.` will output the same byte that was inputted.

- Every `(` must have a matching `)` and vice versa.

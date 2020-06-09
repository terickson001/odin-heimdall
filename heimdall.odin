package heimdall

import "core:os"
import "core:runtime"

Event_Flag :: enum u8
{
     Create,
     Delete,
     Access,
     Modify,
     Close,
     Open,
     Move,
}
Event_Mask :: bit_set[Event_Flag];

Watcher :: struct
{
     handle: os.Handle,
     foci: map[os.Handle][dynamic]Focus,
     unhandled_events: [dynamic]Event,
     
     allocator: runtime.Allocator,
}

Focus :: struct
{
     mask: Event_Mask,
     handle: os.Handle,
     directory: string,
     
     variant : union
         {
         File_Focus,
         Directory_Focus,
     }
}

File_Event_Proc :: #type proc(event: Event, user_data: []any);
File_Focus :: struct
{
     filename: string,
     
     handler: File_Event_Proc,
     user_data: []any,
}

Directory_Event_Proc :: #type proc(event: Event, user_data: []any);
Directory_Focus :: struct
{
     handler: Directory_Event_Proc,
     user_data: []any,
}

Event :: struct
{
     flags: Event_Mask,
     filename: string,
     focus: Focus,
}

// Create Watcher
// Watch Directory
// Watch File
// Un-Watch
// Poll Events
// Async Event Handler
package heimdall

import "core:sys/unix"
import "core:fmt"
import "core:os"
import "core:mem"
import "shared:inotify"
import "path"

@private
to_inotify_mask :: proc(mask: Event_Mask) -> (out_mask: inotify.Event_Mask)
{
    if .Create in mask do out_mask |= {.Create};
    if .Delete in mask do out_mask |= {.Delete};
    if .Access in mask do out_mask |= {.Access};
    if .Modify in mask do out_mask |= {.Modify};
    if .Close  in mask do out_mask |= {.Close_Write, .Close_NoWrite};
    if .Open   in mask do out_mask |= {.Open};
    if .Move   in mask do out_mask |= {.Moved_From, .Moved_To};
    
    return out_mask;
}

@private
from_inotify_mask :: proc(mask: inotify.Event_Mask) -> (out_mask: Event_Mask)
{
    if .Create in mask do out_mask |= {.Create};
    if .Delete in mask do out_mask |= {.Delete};
    if .Access in mask do out_mask |= {.Access};
    if .Modify in mask do out_mask |= {.Modify};
    if transmute(u32)(mask & {.Close_Write, .Close_NoWrite}) != 0 do out_mask |= {.Close};
    if .Open in mask do out_mask |= {.Open};
    if transmute(u32)(mask & {.Moved_From, .Moved_To}) != 0 do out_mask |= {.Move};
    
    return out_mask;
}

init_watcher :: proc(allocator := context.allocator) -> Watcher
{
    watcher := Watcher{};
    watcher.handle = inotify.init();
    watcher.foci = make(T=type_of(watcher.foci), allocator=allocator);
    watcher.unhandled_events = make([dynamic]Event, allocator);
    watcher.allocator = allocator;
    return watcher;
}

clone_any :: proc(a: any, allocator := context.allocator) -> any
{
    raw := transmute(mem.Raw_Any)a;
    ti := type_info_of(raw.id);
    data_clone := mem.alloc(size=ti.size, allocator=allocator);
    mem.copy(data_clone, a.data, ti.size);
    return mem.make_any(data_clone, raw.id);
}

watch_directory :: proc(watcher: ^Watcher, filepath: string, mask: Event_Mask, handler : Directory_Event_Proc = nil, user_data: ..any)
{
    focus := Focus{};
    focus.directory = filepath;
    focus.mask = mask;
    
    data_clone := make([]any, len(user_data), watcher.allocator);
    for a, i in user_data do
        data_clone[i] = clone_any(a, watcher.allocator);
    focus.variant = Directory_Focus{handler=handler, user_data=data_clone};
    
    err: os.Errno;
    focus.handle, err = inotify.add_watch(watcher.handle, focus.directory, to_inotify_mask(mask));
    
    if focus.handle not_in watcher.foci do
        watcher.foci[focus.handle] = make([dynamic]Focus, watcher.allocator);
    append(&watcher.foci[focus.handle], focus);
}

watch_file :: proc(watcher: ^Watcher, filepath: string, mask: Event_Mask, handler: File_Event_Proc = nil, user_data: ..any)
{
    focus := Focus{};
    focus.directory = path.dir(filepath);
    focus.mask = mask;
    
    data_clone := make([]any, len(user_data), watcher.allocator);
    for a, i in user_data do
        data_clone[i] = clone_any(a, watcher.allocator);
    focus.variant = File_Focus{filename=path.base(filepath), handler=handler, user_data=data_clone};
    
    err: os.Errno;
    focus.handle, err = inotify.add_watch(watcher.handle, focus.directory, to_inotify_mask(mask) | {.Mask_Add});
    
    if focus.handle not_in watcher.foci do
        watcher.foci[focus.handle] = make([dynamic]Focus, watcher.allocator);
    append(&watcher.foci[focus.handle], focus);
}

poll_events :: proc(watcher: ^Watcher)
{
    poll_fds := [1]inotify.Poll_Fd{};
    poll_fds[0].fd = cast(i32)watcher.handle;
    poll_fds[0].events = inotify.POLLIN;
    if err := inotify._unix_poll(&poll_fds[0], 1, 0); err <= 0 do
        return;
    
    if poll_fds[0].revents & inotify.POLLIN != 0
    {
        inotify_events := inotify.read_events(fd=watcher.handle, allocator=watcher.allocator);
        for in_event in inotify_events
        {
            foci, ok := watcher.foci[in_event.wd];
            if !ok do
                continue;
            
            event := Event{};
            for focus in foci
            {
                in_mask := from_inotify_mask(transmute(inotify.Event_Mask)in_event.mask);
                if transmute(u8)(focus.mask & in_mask) == 0 do
                    continue;
                switch v in focus.variant
                {
                    case File_Focus:
                    if in_event.name != v.filename do
                        continue;
                    event.flags = in_mask;
                    event.focus = focus;
                    event.filename = in_event.name;
                    if v.handler != nil
                    {
                        v.handler(event, (v.user_data));
                        continue;
                    }
                    
                    case Directory_Focus:
                    event.flags = in_mask;
                    event.focus = focus;
                    event.filename = in_event.name;
                    if v.handler != nil
                    {
                        v.handler(event, (v.user_data));
                        continue;
                    }
                }
                append(&watcher.unhandled_events, event);
            }
        }
        
    }
}

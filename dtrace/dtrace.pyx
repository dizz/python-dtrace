
import time
import threading
from threading import Thread
from dtrace.dtrace_h cimport *

# ----------------------------------------------------------------------------
# The DTrace callbacks
# ----------------------------------------------------------------------------


cdef int chew(dtrace_probedata_t * data, void * arg) with gil:
    '''
    Callback defined by DTrace - will vall the Python callback.

    Called once per fired probe...
    '''

    tmp = <set>arg
    function = <object>tmp[0]

    cpu = data.dtpda_cpu

    function(cpu)

    return 0


cdef int chewrec(dtrace_probedata_t * data, dtrace_recdesc_t * rec,
                 void * arg) with gil:
    '''
    Callback defined by DTrace - will call the Python callback.

    Called once per action.
    '''

    if rec == NULL:
        return 0

    tmp = <set>arg
    function = <object>tmp[1]

    action = rec.dtrd_action
    function(action)

    return 0


cdef int buf_out(dtrace_bufdata_t * buf_data, void * arg) with gil:
    '''
    Callback defined by DTrace - will vall the Python callback.
    '''

    value = buf_data.dtbda_buffered.strip()

    function = <object>arg
    function(value)

    return 0


cdef int walk(dtrace_aggdata_t * data, void * arg) with gil:
    '''
    Callback defined by DTrace - will call the Python callback.
    '''

    keys = []
    value = None

    desc = data.dtada_desc
    id = desc.dtagd_varid
    cdef dtrace_recdesc_t *rec

    aggrec = &desc.dtagd_rec[desc.dtagd_nrecs - 1]
    action = aggrec.dtrd_action

    for i in range(1, desc.dtagd_nrecs - 1):
        rec = &desc.dtagd_rec[i]
        address = data.dtada_data + rec.dtrd_offset

        # TODO: need to extend this.
        if rec.dtrd_size == sizeof(uint32_t):
            keys.append((<int32_t *>address)[0])
        else:
            keys.append(<char *>address)

    if aggrec.dtrd_action in [DTRACEAGG_SUM, DTRACEAGG_MAX, DTRACEAGG_MIN,
                              DTRACEAGG_COUNT]:
        value = (<int *>(data.dtada_data + aggrec.dtrd_offset))[0]
    else:
        raise Exception('Unsupported action')

    function = <object>arg
    function(id, keys, value)

    return 5

# ----------------------------------------------------------------------------
# Default Python callbacks
# ----------------------------------------------------------------------------


cpdef simple_chew(cpu):
    '''
    Simple chew function.

    cpu -- CPU id.
    '''
    print 'Running on CPU:', cpu


cpdef simple_chewrec(action):
    '''
    Simple chewrec callback.

    action -- id of the action which was called.
    '''
    print 'Called action was:', action


cpdef simple_out(value):
    '''
    A buffered output handler for all those prints.

    value -- Line by line string of the DTrace output.
    '''
    print 'Value is:', value


cpdef simple_walk(identifier, keys, value):
    '''
    Simple aggregation walker.

    identifier -- the id.
    keys -- list of keys.
    value -- the value.
    '''
    print identifier, keys, value

# ----------------------------------------------------------------------------
# The consumers
# ----------------------------------------------------------------------------


cdef class DTraceConsumer:
    '''
    A Pyton based DTrace consumer.
    '''

    cdef dtrace_hdl_t * handle
    cdef object out_func
    cdef object walk_func
    cdef object chew_func
    cdef object chewrec_func

    def __init__(self, chew_func=None, chewrec_func=None, out_func=None,
                 walk_func=None):
        '''
        Constructor. Gets a DTrace handle and sets some options.
        '''
        if chew_func is None:
            self.chew_func = simple_chew

        if chewrec_func is None:
            self.chewrec_func = simple_chewrec

        if out_func is None:
            self.out_func = simple_out

        if walk_func is None:
            self.walk_func = simple_walk

        self.handle = dtrace_open(3, 0, NULL)
        if self.handle == NULL:
            raise Exception(dtrace_errmsg(NULL, dtrace_errno(self.handle)))

        # set buffer options
        if dtrace_setopt(self.handle, 'bufsize', '4m') != 0:
            raise Exception(dtrace_errmsg(NULL, dtrace_errno(self.handle)))

        if dtrace_setopt(self.handle, 'aggsize', '4m') != 0:
            raise Exception(dtrace_errmsg(NULL, dtrace_errno(self.handle)))

    def __del__(self):
        '''
        Release DTrace handle.
        '''
        dtrace_close(self.handle)

    cpdef run_script(self, char * script, runtime=1):
        '''
        Run a DTrace script for a number of seconds defined by the runtime.

        After the run is complete the aggregate is walked. During execution the
        stdout of DTrace is redirected to the chew, chewrec and buffered output
        writer.

        script -- The script to run.
        runtime -- The time the script should run in second (Default: 1s).
        '''
        # set simple output callbacks
        if dtrace_handle_buffered(self.handle, & buf_out,
                                  <void *>self.out_func) == -1:
            raise Exception('Unable to set the stdout buffered writer.')

        # compile
        cdef dtrace_prog_t * prg
        prg = dtrace_program_strcompile(self.handle, script,
                                        DTRACE_PROBESPEC_NAME, 0, 0, NULL)
        if prg == NULL:
            raise Exception('Unable to compile the script: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))

        # run
        if dtrace_program_exec(self.handle, prg, NULL) == -1:
            raise Exception('Failed to execute: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))
        if dtrace_go(self.handle) != 0:
            raise Exception('Failed to run_script: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))

        i = 0
        args = (self.chew_func, self.chewrec_func)
        while i < runtime:
            dtrace_sleep(self.handle)
            status = dtrace_work(self.handle, NULL, & chew, & chewrec,
                                 <void *>args)
            if status == 1:
                i = runtime
            else:
                time.sleep(1)
                i += 1

        dtrace_stop(self.handle)

        # walk the aggregate
        # sorting instead of dtrace_aggregate_walk
        if dtrace_aggregate_walk_valsorted(self.handle, & walk,
                                           <void *>self.walk_func) != 0:
            raise Exception('Failed to walk the aggregate: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))


cdef class DTraceContinuousConsumer:
    """
    Continuously consuming DTrace consumer
    """

    cdef dtrace_hdl_t * handle
    cdef object out_func
    cdef object walk_func
    cdef object chew_func
    cdef object chewrec_func
    cdef object script

    def __init__(self, script, chew_func=None, chewrec_func=None,
                 out_func=None, walk_func=None):
        '''
        Constructor. will get the DTrace handle
        '''
        self.script = script

        if chew_func is None:
            self.chew_func = simple_chew

        if chewrec_func is None:
            self.chewrec_func = simple_chewrec

        if out_func is None:
            self.out_func = simple_out

        if walk_func is None:
            self.walk_func = simple_walk

        self.handle = dtrace_open(3, 0, NULL)
        if self.handle == NULL:
            raise Exception(dtrace_errmsg(NULL, dtrace_errno(self.handle)))

        # set buffer options
        if dtrace_setopt(self.handle, 'bufsize', '4m') != 0:
            raise Exception(dtrace_errmsg(NULL, dtrace_errno(self.handle)))

        if dtrace_setopt(self.handle, 'aggsize', '4m') != 0:
            raise Exception(dtrace_errmsg(NULL, dtrace_errno(self.handle)))

    def __del__(self):
        '''
        Release DTrace handle.
        '''
        dtrace_stop(self.handle)
        dtrace_close(self.handle)

    cpdef go(self):
        '''
        Compile DTrace program.
        '''
        # set simple output callbacks
        if dtrace_handle_buffered(self.handle, & buf_out,
                                  <void *>self.out_func) == -1:
            raise Exception('Unable to set the stdout buffered writer.')

        # compile
        cdef dtrace_prog_t * prg
        prg = dtrace_program_strcompile(self.handle, self.script,
                                        DTRACE_PROBESPEC_NAME, 0, 0, NULL)
        if prg == NULL:
            raise Exception('Unable to compile the script: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))

        # run
        if dtrace_program_exec(self.handle, prg, NULL) == -1:
            raise Exception('Failed to execute: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))
        if dtrace_go(self.handle) != 0:
            raise Exception('Failed to run_script: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))

    def sleep(self):
        '''
        Wait for new data to arrive.

        WARN: This method will acquire the Python GIL!
        '''
        dtrace_sleep(self.handle)

    def snapshot(self):
        '''
        Snapshot the data and walk the aggregate.
        '''
        args = (self.chew_func, self.chewrec_func)
        status = dtrace_work(self.handle, NULL, & chew, & chewrec,
                             <void *>args)

        if dtrace_aggregate_snap(self.handle) != 0:
            raise Exception('Failed to get the aggregate: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))
        if dtrace_aggregate_walk(self.handle, & walk,
                                       <void *>self.walk_func) != 0:
            raise Exception('Failed to walk aggregate: ',
                            dtrace_errmsg(NULL, dtrace_errno(self.handle)))

        return status

class DTraceConsumerThread(Thread):
    '''
    Helper Thread which can be used to continuously aggregate.
    '''

    def __init__(self, script, chew_func=None, chewrec_func=None,
                 out_func=None, walk_func=None, sleep=0):
        '''
        Initilizes the Thread.
        '''
        Thread.__init__(self)
        self._stop = threading.Event()
        self.sleep_time = sleep
        self.consumer = DTraceContinuousConsumer(script, chew_func,
                                                 chewrec_func, out_func,
                                                 walk_func)

    def __del__(self):
        '''
        Make sue DTrace stops.
        '''
        del(self.consumer)

    def run(self):
        '''
        Aggregate data...
        '''
        Thread.run(self)

        self.consumer.go()
        while not self.stopped():
            if self.sleep_time == 0:
                self.consumer.sleep()
            else:
                time.sleep(self.sleep_time)

            status = self.consumer.snapshot()
            if status == 1:
                self.stop()

    def stop(self):
        '''
        Stop DTrace.
        '''
        self._stop.set()

    def stopped(self):
        '''
        Used to check the status.
        '''
        return self._stop.isSet()

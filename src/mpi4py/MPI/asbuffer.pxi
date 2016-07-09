#------------------------------------------------------------------------------

cdef extern from "Python.h":
    int PyIndex_Check(object)
    int PySlice_Check(object)
    int PySlice_GetIndicesEx(object, Py_ssize_t,
                             Py_ssize_t *, Py_ssize_t *,
                             Py_ssize_t *, Py_ssize_t *) except -1
    Py_ssize_t PyNumber_AsSsize_t(object, object) except -1

#------------------------------------------------------------------------------

# Python 3 buffer interface (PEP 3118)
cdef extern from "Python.h":
    enum: PY3 "(PY_MAJOR_VERSION>=3)"
    ctypedef struct Py_buffer:
        void *obj
        void *buf
        Py_ssize_t len
        Py_ssize_t itemsize
        bint readonly
        char *format
        #int ndim
        #Py_ssize_t *shape
        #Py_ssize_t *strides
        #Py_ssize_t *suboffsets
    cdef enum:
        PyBUF_SIMPLE
        PyBUF_WRITABLE
        PyBUF_FORMAT
        PyBUF_ND
        PyBUF_STRIDES
        PyBUF_ANY_CONTIGUOUS
        PyBUF_FULL_RO
    int  PyObject_CheckBuffer(object)
    int  PyObject_GetBuffer(object, Py_buffer *, int) except -1
    void PyBuffer_Release(Py_buffer *)
    int  PyBuffer_FillInfo(Py_buffer *, object,
                           void *, Py_ssize_t,
                           bint, int) except -1

# Python 2 buffer interface (legacy)
cdef extern from "Python.h":
    int PyObject_CheckReadBuffer(object)
    int PyObject_AsReadBuffer (object, const void **, Py_ssize_t *) except -1
    int PyObject_AsWriteBuffer(object, void **, Py_ssize_t *) except -1

cdef extern from "Python.h":
    object PyLong_FromVoidPtr(void*)
    void*  PyLong_AsVoidPtr(object)

cdef extern from *:
    void *emptybuffer '((void*)"")'

cdef char BYTE_FMT[2]
BYTE_FMT[0] = c'B'
BYTE_FMT[1] = 0

#------------------------------------------------------------------------------

cdef extern from *:
    enum: PYPY "PyMPI_RUNTIME_PYPY"

cdef type array_array
cdef type numpy_array
cdef int  pypy_have_numpy = 0
if PYPY:
    from array import array as array_array
    try:
        from _numpypy.multiarray import ndarray as numpy_array
        pypy_have_numpy = 1
    except ImportError:
        try:
            from numpypy import ndarray as numpy_array
            pypy_have_numpy = 1
        except ImportError:
            try:
                from numpy import ndarray as numpy_array
                pypy_have_numpy = 1
            except ImportError:
                pass

cdef int \
PyPy_GetBuffer(object obj, Py_buffer *view, int flags) \
except -1:
    cdef object addr
    cdef void *buf = NULL
    cdef Py_ssize_t size = 0
    cdef bint readonly = 0
    if PyObject_CheckBuffer(obj):
        return PyObject_GetBuffer(obj, view, flags)
    if isinstance(obj, bytes):
        buf  = PyBytes_AsString(obj)
        size = PyBytes_Size(obj)
        readonly = 1
    #elif isinstance(obj, bytearray):
    #    buf = <void*> PyByteArray_AsString(obj)
    #    size = PyByteArray_Size(obj)
    #    readonly = 0
    elif isinstance(obj, array_array):
        addr, size = obj.buffer_info()
        buf = PyLong_AsVoidPtr(addr)
        size *= obj.itemsize
        readonly = 0
    elif pypy_have_numpy and isinstance(obj, numpy_array):
        addr, readonly = obj.__array_interface__['data']
        buf = PyLong_AsVoidPtr(addr)
        size = obj.nbytes
    else:
        if (flags & PyBUF_WRITABLE) == PyBUF_WRITABLE:
            readonly = 0
            PyObject_AsWriteBuffer(obj, &buf, &size)
        else:
            readonly = 1
            PyObject_AsReadBuffer(obj, <const void**>&buf, &size)
    if buf == NULL and size == 0: buf = emptybuffer
    PyBuffer_FillInfo(view, obj, buf, size, readonly, flags)
    if (flags & PyBUF_FORMAT) == PyBUF_FORMAT: view.format = BYTE_FMT
    return 0

#------------------------------------------------------------------------------

cdef int \
PyMPI_GetBuffer(object obj, Py_buffer *view, int flags) \
except -1:
    if view == NULL: return 0
    if PYPY: # special-case PyPy runtime
        return PyPy_GetBuffer(obj, view, flags)
    # Python 3 buffer interface (PEP 3118)
    if PY3 or PyObject_CheckBuffer(obj):
        return PyObject_GetBuffer(obj, view, flags)
    # Python 2 buffer interface (legacy)
    if (flags & PyBUF_WRITABLE) == PyBUF_WRITABLE:
        view.readonly = 0
        PyObject_AsWriteBuffer(obj, &view.buf, &view.len)
    else:
        view.readonly = 1
        PyObject_AsReadBuffer(obj, <const void**>&view.buf, &view.len)
    if view.buf == NULL and view.len == 0: view.buf = emptybuffer
    PyBuffer_FillInfo(view, obj, view.buf, view.len, view.readonly, flags)
    if (flags & PyBUF_FORMAT) == PyBUF_FORMAT: view.format = BYTE_FMT
    return 0

#------------------------------------------------------------------------------

@cython.final
cdef class memory:

    """
    Memory
    """

    cdef Py_buffer view

    def __cinit__(self):
        PyBuffer_FillInfo(&self.view, <object>NULL,
                          NULL, 0, 0, PyBUF_SIMPLE)

    def __dealloc__(self):
        PyBuffer_Release(&self.view)

    @staticmethod
    def fromaddress(address, nbytes, readonly=False):
        """Memory from address and size in bytes"""
        cdef void *buf = PyLong_AsVoidPtr(address)
        cdef Py_ssize_t size = nbytes
        if size < 0:
            raise ValueError("expecting non-negative buffer length")
        elif size > 0 and buf == NULL:
            raise ValueError("expecting non-NULL address")
        cdef memory mem = <memory>memory.__new__(memory)
        PyBuffer_FillInfo(&mem.view, <object>NULL,
                          buf, size, readonly, PyBUF_SIMPLE)
        return mem

    # properties

    property address:
        """Memory address"""
        def __get__(self):
            return PyLong_FromVoidPtr(self.view.buf)

    property nbytes:
        """Memory size (in bytes)"""
        def __get__(self):
            return self.view.len

    property readonly:
        """Boolean indicating whether the memory is read-only"""
        def __get__(self):
            return self.view.readonly

    # convenience methods

    def tobytes(self):
        """Return the data in the buffer as a byte string"""
        return PyBytes_FromStringAndSize(<char*>self.view.buf, self.view.len)

    def release(self):
        """Release the underlying buffer exposed by the memory object"""
        PyBuffer_Release(&self.view)
        PyBuffer_FillInfo(&self.view, <object>NULL,
                          NULL, 0, 0, PyBUF_SIMPLE)

    # buffer interface (PEP 3118)

    def __getbuffer__(self, Py_buffer *view, int flags):
        if view == NULL: return
        if view.obj == <void*>None: Py_CLEAR(view.obj)
        if self.view.obj != NULL:
            PyMPI_GetBuffer(<object>self.view.obj, view, flags)
        else:
            PyBuffer_FillInfo(view, self,
                              self.view.buf, self.view.len,
                              self.view.readonly, flags)

    # buffer interface (legacy)

    def __getsegcount__(self, Py_ssize_t *lenp):
        if lenp != NULL:
            lenp[0] = self.view.len
        return 1

    def __getreadbuffer__(self, Py_ssize_t idx, void **p):
        if idx != 0:
            raise SystemError("accessing non-existent buffer segment")
        p[0] = self.view.buf
        return self.view.len

    def __getwritebuffer__(self, Py_ssize_t idx, void **p):
        if self.view.readonly:
            raise TypeError("memory buffer is read-only")
        if idx != 0:
            raise SystemError("accessing non-existent buffer segment")
        p[0] = self.view.buf
        return self.view.len

    # sequence interface (basic)

    def __len__(self):
        return self.view.len

    def __getitem__(self, Py_ssize_t i):
        if i < 0: i += self.view.len
        if i < 0 or i >= self.view.len:
            raise IndexError("index out of range")
        cdef unsigned char *buf = <unsigned char*>self.view.buf
        return <long>buf[i]

    def __setitem__(self, object item, object value):
        if self.view.readonly:
            raise TypeError("memory buffer is read-only")
        cdef unsigned char *buf = <unsigned char*>self.view.buf
        cdef Py_ssize_t start=0, stop=0, step=1, length=0
        cdef memory inmem
        if PyIndex_Check(item):
            start = PyNumber_AsSsize_t(item, IndexError)
            if start < 0: start += self.view.len
            if start < 0 or start >= self.view.len:
                raise IndexError("index out of range")
            buf[start] = <unsigned char>value
        elif PySlice_Check(item):
            PySlice_GetIndicesEx(item, self.view.len,
                                 &start, &stop, &step, &length)
            if step != 1:
                raise IndexError("slice with step not supported")
            if PyIndex_Check(value):
                <void>memset(buf+start, <unsigned char>value, <size_t>length)
            else:
                inmem = getbuffer(value, 1, 0)
                if inmem.view.len != length:
                    raise ValueError("slice length does not match buffer")
                <void>memmove(buf+start, inmem.view.buf, <size_t>length)
        else:
            raise TypeError("indices must be integers or slices")

#------------------------------------------------------------------------------

cdef inline memory newbuffer():
    return <memory>memory.__new__(memory)

cdef inline memory tobuffer(void *base, Py_ssize_t size):
    cdef memory buf = newbuffer()
    if base == NULL and size == 0: base = emptybuffer
    PyBuffer_FillInfo(&buf.view, <object>NULL, base, size, 0, PyBUF_FULL_RO)
    return buf

cdef inline memory getbuffer(object ob, bint readonly, bint format):
    cdef memory buf = newbuffer()
    cdef int flags = PyBUF_ANY_CONTIGUOUS
    if not readonly:
        flags |= PyBUF_WRITABLE
    if format:
        flags |= PyBUF_FORMAT
    PyMPI_GetBuffer(ob, &buf.view, flags)
    return buf

cdef inline object getformat(memory buf):
    cdef Py_buffer *view = &buf.view
    #
    if view.obj == NULL:
        if view.format != NULL:
            return pystr(view.format)
        else:
            return "B"
    elif view.format != NULL:
        # XXX this is a hack
        if view.format != BYTE_FMT:
            return pystr(view.format)
    #
    cdef object ob = <object>view.obj
    cdef str format = None
    try: # numpy.ndarray
        format = ob.dtype.char
    except (AttributeError, TypeError):
        try: # array.array
            format = ob.typecode
        except (AttributeError, TypeError):
            if view.format != NULL:
                format = pystr(view.format)
    return format

#------------------------------------------------------------------------------

cdef inline memory getbuffer_r(object ob, void **base, MPI_Aint *size):
    cdef memory buf = getbuffer(ob, 1, 0)
    if base != NULL: base[0] = buf.view.buf
    if size != NULL: size[0] = <MPI_Aint>buf.view.len
    return buf

cdef inline memory getbuffer_w(object ob, void **base, MPI_Aint *size):
    cdef memory buf = getbuffer(ob, 0, 0)
    if base != NULL: base[0] = buf.view.buf
    if size != NULL: size[0] = <MPI_Aint>buf.view.len
    return buf

#------------------------------------------------------------------------------

cdef inline memory asmemory(object ob, void **base, MPI_Aint *size):
    cdef memory mem
    if type(ob) is memory:
        mem = <memory> ob
    else:
        mem = getbuffer(ob, 1, 0)
    if base != NULL: base[0] = mem.view.buf
    if size != NULL: size[0] = <MPI_Aint> mem.view.len
    return mem

cdef inline memory tomemory(void *base, MPI_Aint size):
    return tobuffer(base, size)

#------------------------------------------------------------------------------
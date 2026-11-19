"""Equal-arm Fisher exact power via enumerated binomial counts, no Monte Carlo.
Two-sided Fisher conditional p-values; positive-effect rejection only.
Truncation probability is explicitly checked (<1e-10 in every reported result).
"""
import math
import numpy as np
from functools import lru_cache

@lru_cache(None)
def reject_matrix(n,alpha,K=240):
    lg=np.array([math.lgamma(x+1) for x in range(2*n+1)])
    def lc(nn,k): return lg[nn]-lg[k]-lg[nn-k]
    k=np.arange(K+1); out=np.zeros((K+1,K+1),dtype=bool)
    for m in range(2*K+1):
        lo=max(0,m-n); hi=min(n,m); x=np.arange(lo,hi+1)
        pr=np.exp(lc(n,x)+lc(n,m-x)-lc(2*n,m))
        cdf=np.cumsum(pr)
        a=np.arange(max(0,m-K),min(K,m)+1); b=m-a
        small=np.minimum(a,b)
        pv=np.minimum(1.0,2*cdf[small-lo])
        out[a,b]=(pv<=alpha+1e-12)&(a>b)
    return out

def pmf(n,p,K=240):
    if p==0:
        z=np.zeros(K+1); z[0]=1; return z
    logv=np.array([math.lgamma(n+1)-math.lgamma(k+1)-math.lgamma(n-k+1)+k*math.log(p)+(n-k)*math.log1p(-p) for k in range(K+1)])
    a=np.exp(logv)
    if a.sum()<1-1e-10: raise ValueError(('binomial truncation',n,p,float(a.sum())))
    return a

def power(n,p0,p1,alpha):
    return float(pmf(n,p1) @ (reject_matrix(n,alpha) @ pmf(n,p0)))

def mde(n,p0,alpha):
    lo=p0; hi=max(p0*2,p0+0.01)
    while power(n,p0,hi,alpha)<0.8: hi*=1.4
    for _ in range(35):
        mid=(lo+hi)/2
        if power(n,p0,mid,alpha)<0.8: lo=mid
        else: hi=mid
    return hi

if __name__=='__main__':
    # Six events vs zero in equal arms is significant at 5%; five vs zero is not.
    q=reject_matrix(1600,0.05)
    assert q[6,0] and not q[5,0]
    assert np.all(q[np.triu_indices(241)]==False)
    assert abs(pmf(1600,.01).sum()-1)<1e-10
    print('exact power core checked')

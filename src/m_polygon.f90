module m_polygon
  integer, parameter      :: MAX_NR_VERTS = 2**8
  integer, parameter      :: MAX_NR_PARA_EDGES = 2**2
  integer, parameter      :: MAX_MONOMIAL = 5
  integer, parameter      :: DEFAULT_VERTS_PER_SEGMENT = int(MAX_NR_VERTS / 3)

  type tParabola
    real*8                :: normal(2), shift
    real*8                :: kappa0 = 0
  end type

  type tPolygon
    ! Polygon is stored as a list of positions
    real*8                :: verts(2,MAX_NR_VERTS)
    integer               :: nverts = 0

    ! When a polygon is intersected with a parabola we store the corresponding parabola
    ! which is needed for computing moments/derivatives
    logical               :: intersected = .false.
    logical               :: parabolic = .false.
    type(tParabola)       :: parabola

    ! We compute the complement if the parabola has kappa0 > 0, in which case the moments
    ! of the original polygon must be stored
    logical               :: complement = .false. 
    real*8                :: original_moments(3)

    ! The tangential and normal coordinates of the vertices which lie on the parabola
    ! (needed for computation of moments/derivatives)
    integer               :: nedges = 0
    integer               :: first_index(MAX_NR_PARA_EDGES)
    real*8                :: x_tau(2,MAX_NR_PARA_EDGES)
    real*8                :: x_eta(2,MAX_NR_PARA_EDGES)
    
    ! Integrated powers of x_tau, which are needed for computation of moments/derivatives
    integer               :: avail_monomial = -1
    real*8                :: x_tau_power(2,MAX_NR_PARA_EDGES)
    real*8                :: monomials(0:MAX_MONOMIAL,MAX_NR_PARA_EDGES)
    real*8                :: monomials_sum(0:MAX_MONOMIAL)

  contains
    procedure             :: reset
  end type

  abstract interface
    real*8 function levelset_fun(x)
      real*8, intent(in)  :: x(2)
    end function
  end interface


  interface makeBox
    module procedure makeBox_dx, makeBox_xdx
  end interface

  interface cmpVolume
    module procedure cmpVolume_poly
  end interface

  interface cmpMoments
    module procedure cmpMoments_poly
  end interface

  interface makeParabola
    module procedure makeParabola_poly, makeParabola_angle_poly
  end interface

  interface makePlane
    module procedure makePlane_def, makePlane_angle
  end interface

  interface polyApprox
    module procedure polyApprox_polyIn, polyApprox_dxIn
  end interface
contains
  subroutine reset(this)
    implicit none
    
    class(tPolygon)       :: this

    this%nverts = 0
    this%nedges = 0
    this%intersected = .false.
    this%parabolic = .false.
    this%complement = .false.
    this%avail_monomial = -1
  end subroutine

  subroutine makePlane_def(plane, normal, shift)
    implicit none
    
    real*8, intent(in)    :: normal(2), shift
    type(tParabola), intent(inout) :: plane

    plane%normal = normal
    plane%shift = shift
    plane%kappa0 = 0.
  end subroutine

  subroutine makePlane_angle(plane, angle, shift)
    implicit none
    
    real*8, intent(in)    :: angle, shift
    type(tParabola), intent(inout) :: plane

    plane%normal = [dcos(angle), dsin(angle)]
    plane%shift = shift
    plane%kappa0 = 0.
  end subroutine

  subroutine makeParabola_poly(parabola, normal, kappa0, shift)
    implicit none
    
    real*8, intent(in)    :: normal(2), kappa0, shift
    type(tParabola), intent(inout) :: parabola

    parabola%normal = normal
    parabola%kappa0 = kappa0
    parabola%shift = shift
  end subroutine

  subroutine makeParabola_angle_poly(parabola, angle, kappa0, shift)
    implicit none
    
    real*8, intent(in)    :: angle, kappa0, shift
    type(tParabola), intent(inout) :: parabola

    parabola%normal = [dcos(angle), dsin(angle)]
    parabola%kappa0 = kappa0
    parabola%shift = shift
  end subroutine

  subroutine complement(out, in)
    implicit none
    
    type(tParabola), intent(in) :: in
    type(tParabola), intent(inout) :: out

    out%normal = -in%normal
    out%kappa0 = -in%kappa0
    out%shift = -in%shift
  end subroutine
    

  real*8 function cmpVolume_poly(poly) result(vol)
    implicit none
    
    type(tPolygon), intent(inout) :: poly ! inout because volume correction may update monomials and taupower

    ! Local variables
    integer               :: vdx, ndx

    vol = 0
    do vdx=1,poly%nverts
      ndx = vdx + 1
      if (ndx > poly%nverts) ndx = 1

      vol = vol + poly%verts(1,vdx)*poly%verts(2,ndx) - poly%verts(2,vdx)*poly%verts(1,ndx)
    enddo

    vol = vol/2

    if (poly%intersected .and. poly%parabolic) then
      vol = vol + parabola_volume_correction(poly)
      if (poly%complement) then
        vol = poly%original_moments(1) - vol
      endif
    endif
  end function

  subroutine cmpMoments_poly(mom, poly)
    implicit none
    
    type(tPolygon), intent(inout) :: poly
    real*8, intent(out)           :: mom(3)

    ! Local variables
    integer               :: vdx, ndx
    real*8                :: areaTerm

    mom = 0
    do vdx=1,poly%nverts
      ndx = vdx + 1
      if (ndx > poly%nverts) ndx = 1

      areaTerm = poly%verts(1,vdx)*poly%verts(2,ndx) - poly%verts(2,vdx)*poly%verts(1,ndx)
      mom(1) = mom(1) + areaTerm
      mom(2:3) = mom(2:3) + areaTerm * (poly%verts(:,vdx) + poly%verts(:,ndx))
    enddo

    mom(1) = mom(1)/2
    mom(2:3) = mom(2:3)/6

    if (poly%intersected .and. poly%parabolic) then
      mom = mom + parabola_moments_correction(poly)
      if (poly%complement) then
        mom = poly%original_moments - mom
      endif
    endif
  end subroutine

  real*8 function cmpDerivative_volAngle(poly, shiftAngleDerivative) result(der)
    implicit none

    type(tPolygon), intent(inout) :: poly
    real*8, intent(in), optional :: shiftAngleDerivative

    ! Local variables
    real*8                :: shiftAngleDerivative_    

    if (.not. poly%intersected) then
      ! print*, 'ERROR: derivative cannot be computed because polygon was not yet intersected'
      der = 0
      return
    endif
    
    if (.not. present(shiftAngleDerivative)) then 
      der = 0
      ! Force zero volume, so derivative is always zero
      return
      ! shiftAngleDerivative_ = cmpDerivative_shiftAngle(poly)
    endif

    shiftAngleDerivative_ = shiftAngleDerivative
    if (poly%complement) shiftAngleDerivative_ = -shiftAngleDerivative_
    
    if (poly%parabolic) then
      call compute_momonial(poly, 3)
    else
      call compute_momonial(poly, 1)
    endif

    der = poly%monomials_sum(0) * shiftAngleDerivative_ - poly%monomials_sum(1)
    if (poly%parabolic) then
      der = der + poly%monomials_sum(1) * poly%parabola%shift * poly%parabola%kappa0 - &
        (poly%monomials_sum(3) * poly%parabola%kappa0**2) / 2
    endif
    
    if (poly%complement) der = -der
  end function
  
  real*8 function cmpDerivative_volKappa(poly, shiftKappaDerivative) result(der)
    implicit none

    type(tPolygon), intent(inout) :: poly
    real*8, intent(in), optional :: shiftKappaDerivative

    if (.not. poly%intersected) then
      der = 0
      ! print*, 'ERROR: derivative cannot be computed because polygon was not yet intersected'
      return
    endif
    
    if (.not. present(shiftKappaDerivative)) then 
      ! Force zero volume
      der = 0
      return
      ! shiftKappaDerivative = cmpDerivative_shiftKappa(poly)
    endif
    
    call compute_momonial(poly, 2)

    der = poly%monomials_sum(0) * shiftKappaDerivative - poly%monomials_sum(2)/2
    
  end function

  real*8 function cmpDerivative_volShift(poly) result(der)
    implicit none

    type(tPolygon), intent(inout) :: poly

    if (.not. poly%intersected) then
      der = 0
      ! print*, 'ERROR: derivative cannot be computed because polygon was not yet intersected'
      return
    endif
    
    call compute_momonial(poly, 0)

    der = poly%monomials_sum(0)
    
  end function
  
  function cmpDerivative_firstMomentAngle(poly, shiftAngleDerivative) result(der)
    implicit none

    type(tPolygon), intent(inout) :: poly
    real*8, intent(in), optional :: shiftAngleDerivative
    real*8                :: der(2)

    ! Local variables
    real*8                :: shiftAngleDerivative_, der1_eta, der1_tau

    if (.not. poly%intersected) then
      der = 0
      ! print*, 'ERROR: derivative cannot be computed because polygon was not yet intersected'
      return
    endif
    
    if (present(shiftAngleDerivative)) then 
      shiftAngleDerivative_ = shiftAngleDerivative
    else
      ! Force zero volume
      shiftAngleDerivative_ = cmpDerivative_shiftAngle(poly)
    endif
    
    if (poly%parabolic) then
      call compute_momonial(poly, 5)
    else
      call compute_momonial(poly, 2)
    endif

    if (poly%complement) shiftAngleDerivative_ = -shiftAngleDerivative_

    ! we write the derivative in terms of its normal and tangential components
	  ! the normal component is given by
	  ! 	int [grad_s - τ + κ τ(s - κ/2 τ^2)][s - κ/2 τ^2] dτ
    der1_eta = poly%parabola%shift * shiftAngleDerivative_ * poly%monomials_sum(0) - poly%parabola%shift * poly%monomials_sum(1)
    if (poly%parabolic) then
      der1_eta = der1_eta + poly%monomials_sum(3) * poly%parabola%kappa0 / 2 - &
        poly%monomials_sum(2) * shiftAngleDerivative_ * poly%parabola%kappa0 / 2 + &
        poly%parabola%kappa0 * (poly%monomials_sum(1) * poly%parabola%shift**2 + &
        poly%monomials_sum(5) * poly%parabola%kappa0**2 / 4 - &
        poly%parabola%shift * poly%parabola%kappa0 * poly%monomials_sum(3))
    endif

    ! and the tangential component
    ! 	int [grad_s - τ + κ τ(s - κ/2 τ^2)]τ dτ
    der1_tau = shiftAngleDerivative_ * poly%monomials_sum(1) - poly%monomials_sum(2)
    if (poly%parabolic) then
      der1_tau = der1_tau + poly%parabola%kappa0 * poly%parabola%shift * poly%monomials_sum(2) -&
        poly%monomials_sum(4) * poly%parabola%kappa0**2 / 2
    endif
    
    der(1) = poly%parabola%normal(1) * der1_eta - poly%parabola%normal(2) * der1_tau
    der(2) = poly%parabola%normal(2) * der1_eta + poly%parabola%normal(1) * der1_tau

    if (poly%complement) der = -der
  end function

    ! The derivative of the shift w.r.t. to the normal angle is given by
	! 	-int [(s - κ/2 τ^2) κ τ - τ] dτ / int 1 dτ
  real*8 function cmpDerivative_shiftAngle(poly) result(der)
    implicit none

    type(tPolygon), intent(inout) :: poly

    if (.not. poly%intersected) then
      der = 0
      ! print*, 'ERROR: derivative cannot be computed because polygon was not yet intersected'
      return
    endif

    if (poly%parabolic) then
      call compute_momonial(poly, 3)
    else
      call compute_momonial(poly, 1)
    endif

    if (poly%monomials_sum(0)==0) then
      der = 0
      return
    endif

    der = poly%monomials_sum(1)
    if (poly%parabolic) then
      der = der - poly%monomials_sum(1) * poly%parabola%shift * poly%parabola%kappa0 &
        + (poly%monomials_sum(3) * poly%parabola%kappa0**2) / 2
    endif
    der = der / poly%monomials_sum(0)

    if (poly%complement) der = -der
  end function

  ! The derivative of the shift w.r.t. to the curvature is given by
	! 	int [τ^2/2] dτ / int 1 dτ
  real*8 function cmpDerivative_shiftKappa(poly) result(der)
    implicit none

    type(tPolygon), intent(inout) :: poly

    if (.not. poly%intersected) then
      der = 0
      ! print*, 'ERROR: derivative cannot be computed because polygon was not yet intersected'
      return
    endif

    call compute_momonial(poly, 2)

    if (poly%monomials_sum(0)==0) then
      der = 0
      return
    endif

    der = (poly%monomials_sum(2)/2) / poly%monomials_sum(0)
  end function

  subroutine intersect(poly, parabola)

    implicit none

    type(tPolygon), intent(inout) :: poly
    type(tParabola), intent(in) :: parabola

    ! Local variables
    real*8                :: dist(MAX_NR_VERTS), buffer(2,MAX_NR_VERTS), coeffs(2)
    integer               :: edx, vdx, ndx, inside_count, first_inside, new_count, nr_coeffs, tdx, prev_idx, next_idx
    logical               :: is_parabolic, edge_is_bisected, edge_could_be_trisected, new_vertex(2), on_parabola(MAX_NR_VERTS)
    real*8                :: x_eta, x_tau

    if (poly%intersected .and. poly%parabolic) then
      print*, 'ERROR: a polygon cannot be intersected if it was previously intersected by a parabola'
      return
    endif

    is_parabolic = parabola%kappa0 /= 0
    if (is_parabolic .and. parabola%kappa0 > 0) then 
      call cmpMoments(poly%original_moments, poly)
      poly%complement = .true.
    endif

    ! Check for each vertex if it under or above the parabola
    inside_count = 0
    first_inside = 0
    do vdx=1,poly%nverts
      x_eta = mydot(poly%verts(:,vdx), parabola%normal) - parabola%shift
      dist(vdx) = x_eta
      if (is_parabolic) then
        x_tau = dot_rotate(poly%verts(:,vdx), parabola%normal)
        dist(vdx) = dist(vdx) + (parabola%kappa0/2) * x_tau**2
        if (poly%complement) dist(vdx) = -dist(vdx)
      endif
      if (dist(vdx) <= 0) then 
        inside_count = inside_count + 1
        if (first_inside == 0) first_inside = vdx
      endif
    enddo

    if (.not. is_parabolic) then
      if (inside_count==0) then
        call poly%reset
        return
      elseif (inside_count==poly%nverts) then
        return
      endif
    endif

    ! Store old vertices
    buffer(:,1:poly%nverts) = poly%verts(:,1:poly%nverts)

    ! Loop over edges of old polygon: insert new vertices and keep some old vertices
    new_count = 0
    nr_coeffs = 0
    vdx = merge(first_inside, 1, first_inside>0)
    do edx=1,poly%nverts
      ndx = vdx + 1
      if (ndx > poly%nverts) ndx = 1

      new_vertex = .false.
      edge_is_bisected = dist(vdx)<=0 .neqv. dist(ndx)<=0
      edge_could_be_trisected = .false.
      if (is_parabolic) then 
        if (.not. edge_is_bisected) then
          edge_could_be_trisected = dist(vdx) <= 0
        endif
        if (edge_is_bisected .or. edge_could_be_trisected) then
          nr_coeffs = parabola_line_intersection(coeffs, parabola, buffer(:,vdx), buffer(:,ndx))
        endif
      endif

      if (edge_is_bisected) then
        ! Insert new vertex (edge bisection)
        if (.not. is_parabolic) then
          coeffs(1) = abs(dist(vdx) / (dist(ndx) - dist(vdx)))
        else
          if (abs(coeffs(2) - .5) < abs(coeffs(1) - .5)) then 
            coeffs(1) = coeffs(2)
          endif
        endif
        new_vertex(1) = .true.
      elseif (edge_could_be_trisected) then
        if (coeffs(2) < coeffs(1)) coeffs = coeffs([2, 1])
        if (nr_coeffs==2) then
          new_vertex = .true.
        elseif (nr_coeffs/=-1) then
          if (abs(coeffs(1)) < 1D-14 .and. abs(coeffs(2)-1) < 1D-14) then
            prev_idx = merge(vdx - 1, poly%nverts, vdx>1)
            next_idx = merge(ndx + 1, 1, ndx<poly%nverts)

            new_vertex(1) = dist(prev_idx)<=0 .eqv. dist(vdx)<=0
            new_vertex(2) = dist(next_idx)<=0 .eqv. dist(ndx)<=0
          endif
        endif
      endif

      do tdx=1,2
        if (new_vertex(tdx)) then
          new_count = new_count + 1
          on_parabola(new_count) = .true.
          poly%verts(:,new_count) = (1 - coeffs(tdx)) * buffer(:,vdx) + coeffs(tdx) * buffer(:,ndx)
        endif
      enddo

      if (dist(ndx)<=0) then
        ! Keep old
        new_count = new_count + 1
        on_parabola(new_count) = .false.
        poly%verts(:,new_count) = buffer(:,ndx)
      endif

      vdx = ndx
    enddo

    poly%nverts = new_count

    poly%parabolic = is_parabolic
    poly%intersected = .true.
    poly%avail_monomial = -1
    if (.not. poly%complement) then
      poly%parabola = parabola
    else
      call complement(out=poly%parabola, in=parabola)
    endif

    poly%nedges = 0
    do vdx=1,poly%nverts
      ndx = vdx + 1
      if (ndx > poly%nverts) ndx = 1
      if (on_parabola(vdx) .and. on_parabola(ndx)) then
        poly%nedges = poly%nedges + 1
        poly%first_index(poly%nedges) = vdx
      endif
    enddo
   
  end subroutine

  subroutine compute_momonial(poly, nr)
    implicit none
    
    type(tPolygon), intent(inout) :: poly
    integer, intent(in)   :: nr

    ! Local variables
    integer               :: mdx, vdx, ndx, old_nr, edx
    
    old_nr = poly%avail_monomial
    if (nr <= old_nr) return
    if (nr > MAX_MONOMIAL) then
      print*, 'ERROR in compute_momonial: too many monomials requested'
    endif

    if (poly%nedges > MAX_NR_PARA_EDGES) then
      print*, 'ERROR: cannot store monomial integral, too many edges'
      return
    endif

    if (old_nr<0) old_nr = -1

    ! We compute integral of x_tau^mdx over edges which are parabola
    poly%monomials_sum(old_nr+1:nr) = 0
    do edx=1,poly%nedges
      vdx = poly%first_index(edx)
      ndx = vdx + 1
      if (vdx==poly%nverts) ndx = 1

      if (old_nr==-1) then 
        poly%x_tau_power(:,edx) = 1
        poly%x_tau(1,edx) = dot_rotate(poly%verts(:,vdx), poly%parabola%normal)
        poly%x_tau(2,edx) = dot_rotate(poly%verts(:,ndx), poly%parabola%normal)
        
        poly%x_eta(1,edx) = mydot(poly%verts(:,vdx), poly%parabola%normal) - poly%parabola%shift
        poly%x_eta(2,edx) = mydot(poly%verts(:,ndx), poly%parabola%normal) - poly%parabola%shift
      endif
      
      do mdx=old_nr+1,nr
        poly%x_tau_power(:,edx) = poly%x_tau_power(:,edx) * poly%x_tau(:,edx)

        poly%monomials(mdx,edx) = (poly%x_tau_power(2,edx) - poly%x_tau_power(1,edx)) / (mdx+1)
        poly%monomials_sum(mdx) = poly%monomials_sum(mdx) + poly%monomials(mdx,edx)
      enddo
    enddo

    poly%avail_monomial = nr
  end subroutine

  real*8 function parabola_volume_correction(poly) result(vol)
    implicit none
    
    type(tPolygon), intent(inout) :: poly

    ! Local variables
    real*8                :: coeff(2), dtau, x_tau(2), x_eta(2), monomials(0:2), x_tau_power(2)
    integer               :: edx, mdx, vdx, ndx

    vol = 0
    if (poly%nedges <= MAX_NR_PARA_EDGES) then
      call compute_momonial(poly, 2)

      do edx=1,poly%nedges
        dtau = poly%monomials(0,edx)
        if (dtau==0) cycle

        ! in the local coordinates the polygon face is given by
        ! x_η = c_1 * x_τ + c_2
        coeff(1) = (poly%x_eta(2,edx) - poly%x_eta(1,edx)) / dtau
        coeff(2) = (poly%x_eta(2,edx) + poly%x_eta(1,edx)) / 2 - coeff(1) * (poly%x_tau(1,edx) + poly%x_tau(2,edx)) / 2
    
        vol = vol - (poly%parabola%kappa0/2) * poly%monomials(2,edx) - &
          coeff(1) * poly%monomials(1,edx) - coeff(2) * dtau
      enddo
    else
      ! Symmetric difference may yield many parabolic edges, so we accomodate for this (volume only)
      do edx=1,poly%nedges
        vdx = poly%first_index(edx)
        ndx = vdx + 1
        if (vdx==poly%nverts) ndx = 1

        x_tau(1) = dot_rotate(poly%verts(:,vdx), poly%parabola%normal)
        x_tau(2) = dot_rotate(poly%verts(:,ndx), poly%parabola%normal)

        x_eta(1) = mydot(poly%verts(:,vdx), poly%parabola%normal) - poly%parabola%shift
        x_eta(2) = mydot(poly%verts(:,ndx), poly%parabola%normal) - poly%parabola%shift

        x_tau_power = 1
        do mdx=0,2
          x_tau_power = x_tau_power * x_tau
          monomials(mdx) = (x_tau_power(2) - x_tau_power(1)) / (mdx+1)
        enddo

        dtau = monomials(0)
        if (dtau==0) cycle

        ! in the local coordinates the polygon face is given by
        ! x_η = c_1 * x_τ + c_2
        coeff(1) = (x_eta(2) - x_eta(1)) / dtau
        coeff(2) = (x_eta(2) + x_eta(1)) / 2 - coeff(1) * (x_tau(1) + x_tau(2)) / 2
    
        vol = vol - (poly%parabola%kappa0/2) * monomials(2) - &
          coeff(1) * monomials(1) - coeff(2) * dtau

      enddo
    endif
  end function

  function parabola_moments_correction(poly) result(moments)
    implicit none
    
    type(tPolygon), target, intent(inout) :: poly
    real*8                :: moments(3)

    ! Local variables
    real*8                :: coeff(2), vol_corr, mom_corr(2), dtau
    integer               :: edx, vdx, ndx
    type(tParabola), pointer :: parabola

    call compute_momonial(poly, 4)

    parabola => poly%parabola

    vol_corr = 0
    mom_corr = 0
    do edx=1,poly%nedges
      ! in the local coordinates the polygon face is given by
      ! x_η = c_1 * x_τ + c_2
      dtau = poly%monomials(0,edx)
      if (dtau == 0) cycle
      
      coeff(1) = (poly%x_eta(2,edx) - poly%x_eta(1,edx)) / dtau
      coeff(2) = (poly%x_eta(2,edx) + poly%x_eta(1,edx)) / 2 - coeff(1) * (poly%x_tau(1,edx) + poly%x_tau(2,edx)) / 2
  
      vol_corr = vol_corr - (parabola%kappa0/2) * poly%monomials(2,edx) - &
        coeff(1) * poly%monomials(1,edx) - coeff(2) * dtau

      ! Corrections to first moment in parabola coordinates
      mom_corr(1) = mom_corr(1) - (parabola%kappa0/2) * poly%monomials(3,edx) - (coeff(1) * poly%monomials(2,edx) + &
        coeff(2) * poly%monomials(1,edx))
      mom_corr(2) = mom_corr(2) + parabola%kappa0**2 * poly%monomials(4,edx)/8 - (coeff(1)**2 * poly%monomials(2,edx) + &
        2 * coeff(1) * coeff(2) * poly%monomials(1,edx) + coeff(2)**2 * dtau)/2 
      enddo
      
      moments(1) = vol_corr
      moments(2) = parabola%normal(1) * (mom_corr(2) + parabola%shift * vol_corr) &
        - parabola%normal(2) * mom_corr(1);
      moments(3) = parabola%normal(2) * (mom_corr(2) + parabola%shift * vol_corr) &
        + parabola%normal(1) * mom_corr(1);
  end function

  ! Given a parabola and a line connecting the points pos1, pos2; find the intersection
  integer function parabola_line_intersection(roots, parabola, pos1, pos2) result(nr_roots)
    use m_common
    use m_poly_roots,     only: polynomial_roots_deg2
    implicit none
    
    type(tParabola), intent(in) :: parabola
    real*8, intent(in)    :: pos1(2), pos2(2)
    real*8, intent(out)   :: roots(2)

    ! Local variables
    real*8                :: coeff(3), imag            
    logical               :: root_is_good(2)
    integer               :: rdx

    ! We parametrize the line as: l(t) = pos1 + t * (pos2 - pos1),
    ! and solve for t
    coeff(1) = (parabola%kappa0/2) * dot_relative_rotate(pos2, parabola%normal, pos1)**2
    coeff(2) = parabola%kappa0 * dot_rotate(pos1, parabola%normal) * dot_relative_rotate(pos2, parabola%normal, pos1) &
      + dot_relative(pos2, parabola%normal, pos1)
    coeff(3) = mydot(pos1, parabola%normal) - parabola%shift + (parabola%kappa0/2) * dot_rotate(pos1, parabola%normal)**2

    call polynomial_roots_deg2(coeff, roots, imag)

    if (imag/=0) then
      nr_roots = -1
    else
      nr_roots = 0
      do rdx=1,2
        root_is_good(rdx) = .not. isnan(roots(rdx)) .and. roots(rdx) >= 0 .and. roots(rdx) <= 1
        if (root_is_good(rdx)) nr_roots = nr_roots + 1
      enddo
    
      if (root_is_good(2) .and. .not. root_is_good(1)) then 
        roots = roots([2, 1])
      endif
    endif
  end function

  pure real*8 function dot_relative_rotate(va, vb, vr) result(drr)
    implicit none
    
    real*8, intent(in)    :: va(2), vb(2), vr(2)

    drr = (va(2) - vr(2))*vb(1) - (va(1) - vr(1))*vb(2)
  end function

  pure real*8 function dot_rotate(va, vb) result(dr)
    implicit none
    
    real*8, intent(in)    :: va(2), vb(2)

    dr = va(2)*vb(1) - va(1)*vb(2)
  end function

  pure real*8 function mydot(va, vb) result(dr)
    implicit none
    
    real*8, intent(in)    :: va(2), vb(2)

    dr = va(1)*vb(1) + va(2)*vb(2)
  end function

  pure real*8 function dot_relative(va, vb, vr) result(dr)
    implicit none
    
    real*8, intent(in)    :: va(2), vb(2), vr(2)

    dr = (va(1) - vr(1))*vb(1) + (va(2) - vr(2))*vb(2)
  end function

  subroutine makeBox_dx(poly, dx)
    implicit none

    real*8, intent(in)    :: dx(2)
    type(tPolygon), intent(inout) :: poly ! NOTE: we use inout to prevent unnecessary initialisation

    call poly%reset

    poly%verts(:,1) = [-dx(1)/2, -dx(2)/2]
    poly%verts(:,2) = [dx(1)/2, -dx(2)/2]
    poly%verts(:,3) = [dx(1)/2, dx(2)/2]
    poly%verts(:,4) = [-dx(1)/2, dx(2)/2]

    poly%nverts = 4

  end subroutine

  subroutine makeBox_xdx(poly, x, dx)
    implicit none
    
    real*8, intent(in)    :: x(2), dx(2)
    type(tPolygon), intent(inout) :: poly

    call poly%reset

    poly%verts(:,1) = x + [-dx(1)/2, -dx(2)/2]
    poly%verts(:,2) = x + [dx(1)/2, -dx(2)/2]
    poly%verts(:,3) = x + [dx(1)/2, dx(2)/2]
    poly%verts(:,4) = x + [-dx(1)/2, dx(2)/2]

    poly%nverts = 4

  end subroutine  

  subroutine bounding_box(box, poly)
    implicit none

    type(tPolygon), intent(in) :: poly
    real*8, intent(out)   :: box(2, 2)

    ! Local variables
    integer               :: v, dim

    if (poly%nverts == 0) then
      box = 0
      return
    endif

    box(:, 1) = poly%verts(:,1)
    box(:, 2) = poly%verts(:,1)
    do v=2,poly%nverts
      do dim=1,2
        box(dim, 1) = min(box(dim, 1), poly%verts(dim,v))
        box(dim, 2) = max(box(dim, 2), poly%verts(dim,v))
      enddo
    enddo
  end subroutine

    ! Returns the first edge (2 positions) whose normal equals normal
  function get_edge(poly, normal) result(edge)
    implicit none

    type(tPolygon), intent(in) :: poly
    real*8, intent(in)    :: normal(2)

    real*8                :: edge(2, 2)   

    ! Local variables
    integer               :: vdx, ndx
    real*8                :: difference(2), nrm

    ! TODO make use of poly%on_parabola if normal not given

    do vdx=1,poly%nverts
      ndx = vdx + 1
      if (ndx > poly%nverts) ndx = 1
      edge(:,1) = poly%verts(:,vdx)
      edge(:,2) = poly%verts(:,ndx)

      difference = edge(:,2) - edge(:,1)
      nrm = norm2(difference)
      if (nrm > 0) then
        if (abs(mydot([difference(2), -difference(1)]/nrm, normal) - 1) < 1D-12) return
      endif
    enddo
    edge = 0
  end function

  subroutine init(poly, pos)
    implicit none

    type(tPolygon), intent(inout) :: poly
    real*8, intent(in)    :: pos(1:, 1:)

    ! Local variables
    integer               :: nverts

    call poly%reset

    nverts = size(pos, 2)
    if (nverts > MAX_NR_VERTS .or. size(pos, 1) /= 2) then
      print*, 'ERROR: cannot initialise polygon, wrong input'
      return
    endif

    poly%verts(1:2,1:nverts) = pos(1:2,1:nverts)
    poly%nverts = nverts
  end subroutine

  subroutine shift_by(poly, pos)
    implicit none

    type(tPolygon), intent(inout) :: poly
    real*8, intent(in)    :: pos(2)

    ! Local variables
    integer               :: vdx

    if (poly%intersected) then
      print*, 'ERROR: cannot sift polygon which has already been intersected'
      return
    endif

    do vdx=1,poly%nverts
      poly%verts(:,vdx) = poly%verts(:,vdx) + pos
    enddo
  end subroutine

  subroutine split(polys, parabola, out_pos, out_neg)
    implicit none

    type(tPolygon), intent(in) :: polys(1:)
    type(tParabola), intent(in) :: parabola
    type(tPolygon), intent(inout) :: out_pos(1:), out_neg(1:)

    ! Local variables
    integer               :: vdx
    type(tParabola)       :: c_parabola

    call complement(out=c_parabola, in=parabola)

    do vdx=1,size(polys, 1)
      call copy(out=out_pos(vdx), in=polys(vdx))
      call intersect(out_pos(vdx), parabola)
    
      call copy(out=out_neg(vdx), in=polys(vdx))
      call intersect(out_neg(vdx), c_parabola)
    enddo
  end subroutine

  ! NOTE: returning poly by function is much more expensive than returning via subroutine!
  subroutine copy(out, in)
    implicit none
    
    type(tPolygon), intent(in) :: in
    type(tPolygon), intent(inout):: out

    call out%reset
    
    out%nverts = in%nverts
    out%verts(:,1:out%nverts) = in%verts(:,1:out%nverts)
    
    out%intersected = in%intersected
    if (in%intersected) then
      out%parabola%normal = in%parabola%normal
      out%parabola%shift = in%parabola%shift
      out%parabola%kappa0 = in%parabola%kappa0

      out%parabolic = in%parabolic
      out%nedges = in%nedges
      out%first_index(1:out%nedges) = in%first_index(1:out%nedges)

      if (out%parabolic) then
        out%complement = in%complement
        if (in%complement) out%original_moments = in%original_moments
  
        out%avail_monomial = in%avail_monomial
        if (out%avail_monomial>=0) then 
          out%x_tau(:,1:out%nedges) = in%x_tau(:,1:out%nedges)
          out%x_eta(:,1:out%nedges) = in%x_eta(:,1:out%nedges)

          out%x_tau_power = in%x_tau_power
          out%monomials = in%monomials
          out%monomials_sum = in%monomials_sum
        endif
      endif

    endif

  end subroutine

  subroutine polyApprox_dxIn(poly, x, dx, levelSet, phase, verts_per_segment)
    use m_common
    use m_optimization,   only: brent
  
    implicit none

    type(tPolygon), intent(inout) :: poly
    real*8, intent(in)    :: x(2), dx(2)
    procedure(levelset_fun) :: levelSet
    integer, intent(in), optional :: phase
    integer, intent(in), optional :: verts_per_segment

    type(tPolygon)        :: cell

    call makeBox(cell, x, dx)
    call polyApprox_polyIn(poly, cell, levelSet, phase, verts_per_segment)
  end subroutine

  subroutine polyApprox_polyIn(poly, cell, levelSet, phase, verts_per_segment)
    use m_common
    use m_optimization,   only: brent
  
    implicit none

    type(tPolygon), intent(in) :: cell
    procedure(levelset_fun) :: levelSet
    integer, intent(in), optional :: phase
    integer, intent(in), optional :: verts_per_segment
    type(tPolygon), intent(inout) :: poly

    ! Local variables
    real*8                :: pos(2, MAX_NR_VERTS), pos_skeleton(2, MAX_NR_VERTS), funVals(MAX_NR_VERTS)
    real*8                :: x0(2), dir(2), step, tDir(2), bbox(2, 2), lengthScale
    integer               :: edx, vdx, vdx_first_inside, nrPos, vdx_next, nrPos_skelelton, rdx
    integer               :: verts_per_segment_, phase_, tmp
    logical               :: vdx_is_inside, vdx_next_is_inside, is_on_interface(MAX_NR_VERTS)

    call poly%reset

    verts_per_segment_ = DEFAULT_VERTS_PER_SEGMENT
    if (present(verts_per_segment)) verts_per_segment_ = min(verts_per_segment_, verts_per_segment)

    phase_ = merge(phase, LIQUID_PHASE, present(phase))

    ! Find out which vertices of the cell are inside the domain
    vdx_first_inside = 0
    do vdx=1,cell%nverts
      funVals(vdx) = interfaceFun(cell%verts(:,vdx))
      if (funVals(vdx) < 0 .and. vdx_first_inside == 0) vdx_first_inside = vdx
    enddo
    if (vdx_first_inside == 0) return

    ! Loop over the edges and construct the polygonal 'skeleton'
    vdx = vdx_first_inside
    vdx_is_inside = .true.
    nrPos_skelelton = 0

    do edx=1,cell%nverts
      vdx_next = vdx + 1
      if (vdx_next > cell%nverts) vdx_next = 1
      vdx_next_is_inside = funVals(vdx_next) < 0.0

      ! TODO so far we assume that an edge has at most one intersection
      if (vdx_is_inside .neqv. vdx_next_is_inside) then
        ! Find and add new position
        x0 = cell%verts(:,vdx)
        dir = cell%verts(:,vdx_next) - x0
        step = brent(interfaceFun_step, 0.0D0, 1.0D0, 1D-15, 52, funVals(vdx), funVals(vdx_next))
        nrPos_skelelton = nrPos_skelelton + 1
        pos_skeleton(:,nrPos_skelelton) = x0 + step * dir
        is_on_interface(nrPos_skelelton) = .true.
      endif
      if (vdx_next_is_inside) then
        ! And add next node (corner)
        nrPos_skelelton = nrPos_skelelton + 1
        pos_skeleton(:,nrPos_skelelton) = cell%verts(:,vdx_next)
        is_on_interface(nrPos_skelelton) = .false.
      endif

      vdx = vdx_next
      vdx_is_inside = vdx_next_is_inside
    enddo

    call bounding_box(bbox, cell)
    lengthScale = norm2(bbox(:,2) - bbox(:,1))

    ! Now we add a refined approximation on edges that are on the interface
    nrPos = 0
    vdx = 1
    tmp = 0
    do edx=1,nrPos_skelelton
      vdx_next = merge(1, vdx + 1, vdx == nrPos_skelelton)

      if (nrPos > MAX_NR_VERTS - DEFAULT_VERTS_PER_SEGMENT) then
        print*, 'ERROR: number of vertices in polyApprox at risk of exceeding max nr vertices'
        poly%nverts = 0
        return
      endif

      ! Add (refinement of) the half open interval (pos_skeleton(:,vdx),pos_skeleton(:,vdx_next)]
      if (.not. is_on_interface(vdx) .or. .not. is_on_interface(vdx_next)) then
        nrPos = nrPos + 1
        pos(:,nrPos) = pos_skeleton(:,vdx_next)
      else

        tDir = pos_skeleton(:,vdx_next) - pos_skeleton(:,vdx)
        if (norm2(tDir) < 1D-15 * lengthScale) then
          nrPos = nrPos + 1
          pos(:,nrPos) = pos_skeleton(:,vdx_next)
        else
          ! Refine the face
          tmp = tmp + 1
          ! Make dir normal to the face
          dir = [-tDir(2), tDir(1)]
          do rdx=1,verts_per_segment_
            x0 = pos_skeleton(:,vdx) + rdx * tDir / verts_per_segment_

            ! We impose here that the radius of curvature of the interface is bounded from below by half (relative to the mesh spacing)
            step = brent(interfaceFun_step, -.5D0, .5D0, 1D-15, 52)

            nrPos = nrPos + 1
            pos(:,nrPos) = x0 + step * dir
          enddo
        endif
      endif

      vdx = vdx_next
    enddo

    call init(poly, pos(:,1:nrPos))
  contains

    real*8 function interfaceFun(x) result(f)
  
      implicit none

      real*8, intent(in)  :: x(2)

      f = levelSet(x)
      if (phase_ == GAS_PHASE) f = -f
    end

    real*8 function interfaceFun_step(step_) result(f)
      implicit none

      real*8, intent(in)    :: step_

      f = interfaceFun(x0 + step_ * dir)
    end
  end subroutine
end